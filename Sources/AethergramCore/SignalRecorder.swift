import Foundation
import os
import Synchronization

/// The package's one entry point: consent gate, durable queue, batching,
/// backoff, and the retention counters, over a transport it knows nothing
/// about.
///
/// **Consent is the invariant, not a filter.** Until `updateConsent(.granted)`
/// lands, `record` enqueues nothing, writes nothing, resolves no identifier,
/// advances no counter, and reaches no transport; a later decline purges the
/// queue and the counters rather than merely stopping new writes. Every one of
/// those clauses is asserted in `ConsentEnforcementTests`, because a
/// transport-only assertion cannot tell "dropped before enqueue" from
/// "enqueued but not yet sent", and only the first is what consent requires.
///
/// **Recording is synchronous and never throws.** Consumers emit from view
/// code and lifecycle hooks; a call that could suspend would change every call
/// site and a call that could fail would put error handling on paths that have
/// nothing useful to do with the error. Queue persistence and transmission
/// are deferred off the caller; a retention checkpoint is saved on the
/// caller's thread, under the recorder's lock.
public final class SignalRecorder: Sendable {
    // MARK: Lifecycle

    /// Every host seam but the transport and the queue's writes is called
    /// with the recorder's lock held. That lock is not recursive: a seam that
    /// calls back into the recorder terminates the process at the entry point
    /// it called.
    ///
    /// - Parameters:
    ///   - configuration: Batching, delivery, and logging policy, read for the
    ///     life of the recorder.
    ///   - transport: Where batches go. Called from the recorder's own drain
    ///     task at utility priority and never under its lock, so a send may
    ///     suspend for as long as the network takes.
    ///   - queueStorage: The durable queue. `load()` is called under the lock,
    ///     at most once per recorder; `persist` and `purge` run on the
    ///     recorder's serial writer queue. None may call back into the
    ///     recorder.
    ///   - retentionStore: Where the session counters live. Every call is made
    ///     under the lock, and none may call back into the recorder.
    ///   - clientUserProvider: Resolves the consumer's analytics identifier.
    ///     Called only on a transmit that consent already permits, so an
    ///     implementation that mints and persists an identifier on first read
    ///     cannot plant one before the answer. Called under the lock on the
    ///     drain's thread rather than any caller's: it must be cheap,
    ///     must not hop to the main actor — `MainActor.assumeIsolated` traps
    ///     there, and `DispatchQueue.main.sync` deadlocks against a record the
    ///     main thread is making — and must not call back into the recorder.
    ///   - environmentProvider: The authored default payload. Called at most
    ///     once per grant, on the first permitted record, for the same reason.
    ///     It cannot drop the package's identity: the recorder stamps
    ///     `sdk.name`, `sdk.version`, and `sdk.nameAndVersion` itself.
    ///     Called under the lock on whichever thread made that record, with
    ///     the same constraints as `clientUserProvider`.
    ///   - calendar: The calendar day-keyed counters and the hour-of-day field
    ///     are computed in.
    ///   - now: The clock stamped on every signal and session boundary. A
    ///     retry deadline does not read it: that is measured on a monotonic
    ///     clock, so a wall-clock change cannot move it.
    public convenience init(
        configuration: AethergramConfiguration,
        transport: any SignalTransport,
        queueStorage: any SignalQueueStorage,
        retentionStore: any RetentionStore,
        clientUserProvider: @escaping @Sendable () -> String?,
        environmentProvider: @escaping @Sendable () -> [String: String] = { EnvironmentSnapshot.current().parameters },
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            configuration: configuration,
            transport: transport,
            queueStorage: queueStorage,
            retentionStore: retentionStore,
            clientUserProvider: clientUserProvider,
            environmentProvider: environmentProvider,
            calendar: calendar,
            now: now,
            retryDelay: { failures in
                var generator = SystemRandomNumberGenerator()
                return configuration.backoffInterval(consecutiveFailures: failures, using: &generator)
            }
        )
    }

    /// The public initializer with the retry draw exposed, so a test can fix
    /// what a production recorder leaves to the system generator, and the
    /// drain's delay, so a test can see a sleeping drain cancelled.
    init(
        configuration: AethergramConfiguration,
        transport: any SignalTransport,
        queueStorage: any SignalQueueStorage,
        retentionStore: any RetentionStore,
        clientUserProvider: @escaping @Sendable () -> String?,
        environmentProvider: @escaping @Sendable () -> [String: String],
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        retryDelay: @escaping @Sendable (_ consecutiveFailures: Int) -> TimeInterval,
        sleep: @escaping @Sendable (_ seconds: TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.retryDelay = retryDelay
        self.sleep = sleep
        self.configuration = configuration
        self.transport = transport
        self.queueStorage = queueStorage
        writer = QueueWriter(storage: queueStorage, label: "\(configuration.logSubsystem).aethergram-queue-writer")
        // What a late read carries is bounded by this recorder's limit, not
        // the store's default, or a host queueing more loses the oldest.
        (queueStorage as? any QueueLimitAdopting)?.adoptQueueLimit(configuration.queueLimit)
        self.retentionStore = retentionStore
        self.clientUserProvider = clientUserProvider
        self.environmentProvider = environmentProvider
        self.calendar = calendar
        self.now = now
        logger = Logger(subsystem: configuration.logSubsystem, category: "aethergram")
    }

    /// Cancels a drain that has not started sending. One that has holds the
    /// recorder until its pass ends, so it is never here.
    deinit {
        lock.withLock { $0.drain.owned?.task }?.cancel()
    }

    // MARK: Public

    /// Adopts the consumer's consent answer. Granting only opens the gate;
    /// anything other than granted closes it *and* erases what was collected
    /// under it — the queue file, the retention counters, and the pending
    /// batch — because a toggle that leaves yesterday's signals on disk to be
    /// sent later is not an off switch.
    ///
    /// A non-granted answer blocks the caller until the erase reaches the
    /// queue store. A send already handed to the transport is cancelled, not
    /// recalled: a transport that honours cancellation stops it.
    public func updateConsent(_ state: ConsentState) {
        requireNoReentry()
        let erased: (happened: Bool, drain: Task<Void, Never>?, queued: Int) = lock.withLock { current in
            current.consent = state
            guard !state.permitsCollection else {
                // A grant during a closing reset takes effect at its reopen.
                guard current.gateOpen else { return (false, nil, 0) }
                Self.openSessionIfNeeded(&current)
                restoreQueueIfNeeded(&current)
                return (false, nil, current.pending.count)
            }
            eraseCollected(&current)
            return (true, Self.detachOwnedDrain(&current), 0)
        }
        waiters.resumeSettled(writer: writer)
        guard erased.happened else {
            logger.info("consent granted")
            // A queue a killed process left has nobody else coming for it:
            // the host may record nothing before it is suspended again.
            if erased.queued > 0 {
                startDrain(after: configuration.deliveryDelay(queued: erased.queued))
            }
            return
        }
        erased.drain?.cancel()
        awaitErasure()
        logger.info("consent withheld state=\(state.rawValue, privacy: .public) queue purged")
    }

    /// Records a consumer signal. The configured prefix is applied here.
    public func record(_ name: String, parameters: [String: String] = [:], floatValue: Double? = nil) {
        requireNoReentry()
        enqueue(name: configuration.signalPrefix + name, parameters: parameters, floatValue: floatValue)
    }

    /// Records the purchase preset. Unprefixed: the name is the package's, and
    /// each adapter maps it onto its vendor's own purchase event.
    public func recordPurchaseCompleted(_ details: PurchaseDetails, parameters: [String: String] = [:]) {
        requireNoReentry()
        enqueue(
            name: PresetSignal.purchaseCompleted.rawValue,
            parameters: details.parameters.merging(parameters) { $1 },
            floatValue: details.price
        )
    }

    /// Records the error preset. `id` is the consumer's vocabulary; the package
    /// only carries it.
    ///
    /// `id` is assigned last, so it wins a collision with `parameters`. That is
    /// not the caller-wins rule the recorder applies to package defaults: this key
    /// carries the signal's identity and arrives through its own argument, so a
    /// stray dictionary entry under the same name is a mistake rather than a
    /// more specific value.
    public func recordError(id: String, parameters: [String: String] = [:]) {
        requireNoReentry()
        var combined = parameters
        combined[PayloadKey.errorID] = id
        enqueue(name: PresetSignal.errorOccurred.rawValue, parameters: combined, floatValue: nil)
    }

    /// Opens a session for the counters. A session boundary is host-specific —
    /// a short-lived extension process has no app foreground to key off — so
    /// the host calls it and the package counts.
    public func beginSession() {
        requireNoReentry()
        lock.withLock { current in
            guard current.gateOpen else { return }
            openCountedSession(&current)
        }
    }

    /// Closes the session opened by `beginSession()` and folds its duration
    /// into the averages.
    ///
    /// Only a session this instance opened. One inherited from another
    /// process is left for the next `beginSession()` to close against its own
    /// checkpoint: the store may be shared with a process still running that
    /// session, and closing it against this clock counts time nobody spent.
    public func endSession() {
        requireNoReentry()
        lock.withLock { current in
            guard current.gateOpen, current.ownsOpenSession,
                  let existing = current.retention else { return }
            current.openedSessionAt = nil
            let record = RetentionCounters.recordingSessionEnd(in: existing, at: now())
            current.retention = record
            retentionStore.save(record)
        }
    }

    /// Best-effort send now. Called on the consumer's deactivation hook, where
    /// the process may not survive long enough to finish — which is why the
    /// queue is durable rather than why this call blocks.
    ///
    /// Blocks the caller until every queue write submitted before the call
    /// has reached the store. A write submitted after the call, from any
    /// thread, is not promised by the return, and lengthens the wait by at
    /// most one store call. It does not wait for the send.
    public func flush() {
        requireNoReentry()
        // The consumer calls this on its way out of an active cycle, which is
        // the one moment a not-yet-written queue would be lost rather than
        // merely late.
        writer.waitForPendingWrites()
        startDrain(after: 0)
    }

    /// `flush()` for a caller that can wait for the send: one attempt at
    /// delivering what was queued when it was called, so a host can bracket
    /// it with an expiring-activity window. It always returns promptly when
    /// cancelled.
    ///
    /// At the call it notes the signals queued — or, when the recorder's
    /// lock is busy then, as soon as it is free — and starts a drain at zero
    /// delay, or joins the one already sending. It returns on the first of:
    /// - Those signals have all left the queue — delivered, permanently
    ///   rejected, or evicted by overflow — and the store has attempted the
    ///   write that records the removal. That write covers every queue write
    ///   submitted before it.
    /// - A send fails and a retry is owed, including when no identifier
    ///   resolves.
    /// - A retry was already owed at the call. It returns at once and never
    ///   hurries that retry, for the same reason `flush()` does not.
    /// - The queue is erased: a decline, a `reset()`, or a
    ///   `resetClosingCollection(during:)`.
    /// - Consent is not granted, or collection is closed for a reset.
    /// - The calling task is cancelled.
    ///
    /// Records made after the call are never waited for. A queue write one
    /// of them submits can lengthen the wait for the removal by at most one
    /// store call, as it can `flush()`'s. No return but the first waits for
    /// a queue write; `flush()` is the call that does.
    ///
    /// What the attempt can lose or repeat: a removal the store fails to
    /// write leaves the batch on disk, and a later process sends it again;
    /// overflow eviction and a permanent rejection drop signals. It loses
    /// and repeats nothing else.
    ///
    /// Cancellation ends the wait without taking the recorder's lock, so a
    /// restore or an identifier resolution holding that lock cannot delay
    /// the return. It ends neither the send, whose batch is on disk either
    /// way, nor the queue writes: work submitted to the writer keeps running
    /// on the writer's queue, and retains the writer until it finishes.
    ///
    /// Named apart from `flush()` because an async overload of one name wins
    /// in every async context, which would turn each existing unawaited call
    /// there into a compile error.
    public func flushAndWait() async {
        requireNoReentry()
        let id = waiters.mint()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.arm(id, continuation)
                // A cancel that arrived before the arm found nothing to resume.
                guard !Task.isCancelled else {
                    waiters.resume(id)
                    return
                }
                // Captured here when the lock is free, so the count is the
                // one at the call. When a restore or an identifier resolution
                // holds it, the caller must not block behind them.
                if let preempted = lock.withLockIfAvailable({ beginAttempt(id, &$0) }) {
                    preempted?.cancel()
                    waiters.resumeSettled(writer: writer)
                } else {
                    Task(priority: .utility) { [weak self, waiters] in
                        guard let self else { return waiters.resume(id) }
                        lock.withLock { beginAttempt(id, &$0) }?.cancel()
                        waiters.resumeSettled(writer: writer)
                    }
                }
            }
        } onCancel: {
            waiters.resume(id)
        }
    }

    /// Erases everything the package persists. Wire it into the host's
    /// data-reset path: this is what makes the retention counters clearable,
    /// which the SDK this replaces offered no way to do.
    ///
    /// Blocks the caller until the erase reaches the queue store, and leaves
    /// consent as it was.
    public func reset() {
        requireNoReentry()
        let detached: Task<Void, Never>? = lock.withLock { current in
            eraseCollected(&current)
            // A reset leaves consent alone, so the gate stays open and the next
            // batch needs a session the erased one cannot be mistaken for.
            Self.openSessionIfNeeded(&current)
            return Self.detachOwnedDrain(&current)
        }
        waiters.resumeSettled(writer: writer)
        detached?.cancel()
        awaitErasure()
        logger.info("reset ok")
    }

    /// `reset()` with collection closed for the length of `body`, for a host
    /// whose data reset also replaces what `clientUserProvider` returns.
    ///
    /// Erases what `reset()` erases and waits for the erase to reach the
    /// queue store, then runs `body` on the calling thread, outside the
    /// recorder's lock, with the gate shut. Until it returns, `record`,
    /// `beginSession()`, and `endSession()` are dropped, no identifier is
    /// resolved, and nothing is sent, as before a grant. A send already
    /// handed to the transport is cancelled and its verdict discarded, as
    /// for `reset()`.
    ///
    /// Collection reopens when `body` returns or throws; an error it throws
    /// reaches the caller after the reopen. Calls nest, and may overlap from
    /// several threads: collection reopens only when the last of them
    /// returns, in whatever order they finish. If consent permits then, the
    /// reopen opens a counted session, as `beginSession()` does, where
    /// `reset()` only mints an uncounted session identifier.
    ///
    /// During `body`:
    /// - a decline erases as usual, and stands after the reopen;
    /// - a grant takes effect at the reopen, not before;
    /// - `flush()` still waits for the queue writes and starts no drain;
    /// - `flushAndWait()` returns at once;
    /// - `reset()` erases and leaves collection closed.
    public func resetClosingCollection<R, E: Error>(during body: () throws(E) -> R) throws(E) -> R {
        requireNoReentry()
        let detached: Task<Void, Never>? = lock.withLock { current in
            current.closedForReset += 1
            eraseCollected(&current)
            return Self.detachOwnedDrain(&current)
        }
        waiters.resumeSettled(writer: writer)
        detached?.cancel()
        awaitErasure()
        logger.info("reset ok collection=closed")
        defer {
            let reopened: Bool = lock.withLock { current in
                current.closedForReset -= 1
                // In the same section as the last decrement, so no record
                // lands between the reopen and its session.
                guard current.gateOpen else { return false }
                openCountedSession(&current)
                return true
            }
            if reopened { logger.info("collection reopened") }
        }
        return try body()
    }

    // MARK: Internal

    /// Every mutation of the durable queue goes through here, never through
    /// `queueStorage` directly; `load()` is the one read and stays direct.
    /// Its barrier waits for the writes submitted before the wait began, and
    /// a later write lengthens it by at most one store call.
    ///
    /// Internal rather than private so a test can wait on the same writes
    /// `flush()` waits on. Both the property and `waitForPendingWrites()` have
    /// production callers, so this widens visibility without adding surface
    /// that exists only for tests.
    let writer: QueueWriter

    /// How many drains this recorder has ever scheduled. A count rather than
    /// the slot, because a slot read after the fact cannot tell a drain that
    /// was never scheduled from one that ran, found nothing, and gave it back.
    var drainsScheduled: Int {
        lock.withLock { $0.lastDrainID }
    }

    /// Seconds until the retry the last failure owes, and zero when none is.
    var secondsUntilRetry: TimeInterval {
        lock.withLock { Self.secondsOwed($0.retryNotBefore) }
    }

    /// How many awaited flushes are registered, so a test can tell a waiter
    /// a cancel removed from one it left behind.
    var flushWaiterCount: Int {
        waiters.count
    }

    /// Sends queued signals until the queue empties or a send fails. Internal
    /// rather than public so tests can await a transmission the consumer only
    /// ever kicks off; `flush()` is the consumer's door.
    func drain() async {
        let claim: Int? = lock.withLock { current in
            guard current.drainClaim == nil else { return nil }
            current.lastClaimID &+= 1
            current.drainClaim = current.lastClaimID
            return current.lastClaimID
        }
        guard let claim else { return }
        defer {
            lock.withLock { current in
                if current.drainClaim == claim { current.drainClaim = nil }
            }
        }
        while await sendNextBatch(claim: claim) {}
    }

    // MARK: Private

    /// The one owned drain, and which stage it is at.
    ///
    /// `waiting` is sleeping out its coalescing delay and can still be hurried;
    /// `running` cannot. Cancelling a running drain would not stop it — an
    /// unstructured task runs its body regardless — so a second task would send
    /// the same batch again and walk straight through the backoff.
    private enum DrainSlot {
        case idle
        case waiting(OwnedDrain)
        case running(OwnedDrain)

        var owned: OwnedDrain? {
            switch self {
            case .idle: nil
            case let .waiting(owned), let .running(owned): owned
            }
        }
    }

    /// The task in the slot, under the identifier it was minted with. A task
    /// names itself when it gives the slot back, because a cancelled or
    /// superseded one reaching that point would otherwise evict the drain that
    /// replaced it.
    private struct OwnedDrain {
        let id: Int
        let task: Task<Void, Never>
    }

    private struct State {
        var consent: ConsentState = .neverAsked
        var pending: [Signal] = []
        var environment: [String: String]?
        var retention: RetentionRecord?
        var retentionLoaded = false
        var queueRestored = false
        /// The drain allowed to claim batches, by the token it claimed with.
        /// A token rather than a flag, so an erase can take the claim from a
        /// drain whose cancelled send has not yet unwound without that drain's
        /// eventual release taking it from the one that replaced it.
        var drainClaim: Int?
        var lastClaimID = 0
        /// At most one drain is owned at a time, and the slot says which of
        /// the three states it is in rather than leaving that to be inferred
        /// from a pair of flags and an optional.
        var drain: DrainSlot = .idle
        /// The last identifier handed to a drain. Monotonic, so an identifier
        /// a task holds is never the one a later task was given.
        var lastDrainID = 0
        var consecutiveFailures = 0
        /// When the next attempt is owed, after a failure. Tracked apart from
        /// the coalescing delay because the two answer different questions: a
        /// delay says how long a batch may wait for company, and this says how
        /// long the endpoint gets before it is asked again. A zero-delay
        /// request may collapse the first and never the second.
        ///
        /// Continuous rather than the injected clock: it is compared against
        /// the sleep a drain actually serves, which is `Task.sleep`'s, and a
        /// wall clock that jumps would move a deadline that did not.
        var retryNotBefore: ContinuousClock.Instant?
        var sessionID = ""
        /// The start this instance stamped on the session it opened, so a
        /// repeat `beginSession()` in the same activation can be told apart
        /// from one that inherits a dead process's open session.
        var openedSessionAt: Date?

        /// Whether anything may be collected, queued, or sent now.
        var gateOpen: Bool {
            consent.permitsCollection && closedForReset == 0
        }

        /// Whether the open session is the one this instance stamped, rather
        /// than one left by a dead process or a live one sharing the store.
        var ownsOpenSession: Bool {
            guard let openedSessionAt else { return false }
            return retention?.openSessionStartedAt == openedSessionAt
        }
        /// How many erases this recorder has performed. A batch carries the
        /// value it was claimed under, so work in flight across an erase can be
        /// told from work that belongs to the queue that exists now.
        var eraseGeneration = 0
        /// How many `resetClosingCollection(during:)` callbacks are running.
        /// The gate is shut while any is, whatever consent says.
        var closedForReset = 0
        /// How many signals a record's overflow has ever evicted from the
        /// front of the queue. A restore's overflow is not counted: it always
        /// precedes the first claim. A batch carries the value it was claimed under, which is the only
        /// way to know how much of what it sent the queue still holds: two
        /// signals recorded alike are equal, so a value match cannot tell a
        /// sent signal from the one that replaced it.
        var evictedFromFront = 0
        /// How many signals have ever left the front of the queue, by any
        /// route: delivered, permanently rejected, or evicted by overflow. An
        /// awaited flush compares it against what it saw at the call.
        var dequeuedFromFront = 0
        /// How many attempts have ended owing a retry. Monotonic, unlike
        /// `consecutiveFailures`, so a flush can tell a failure after its call
        /// from the run it started behind.
        var failedAttempts = 0
        /// Signals dropped since the queue last had room, and zero while it
        /// has room. What logs the overflow once on the way in and once on
        /// the way out, rather than on every record in between.
        var droppedInOverflow = 0

        /// Drops everything collected under a grant. Both callers — a decline
        /// and a data reset — mean the same thing by it, and had drifted: only
        /// `reset` zeroed the failure count. It is zeroed for both now, because
        /// a backoff is a property of a queue that no longer exists, and a
        /// later grant should not inherit a stale one.
        ///
        /// `queueRestored` is left true rather than cleared: after the purge
        /// that follows, nothing on disk is ours, and re-reading would let a
        /// later grant resurrect declined-era signals from a file whose
        /// deletion failed, which a decline is supposed to have ended.
        ///
        /// The session and the environment go too: both were read under the
        /// grant being erased, and a regrant that reused the session would join
        /// what follows it to what preceded it.
        ///
        /// The claim goes because everything it could send is gone: the batch
        /// in flight belongs to the erased generation, its verdict is
        /// discarded, and `nextBatch` refuses the old token from here on, so
        /// the drain after this one cannot find itself locked out until the
        /// cancelled send unwinds.
        mutating func eraseCollected() {
            pending = []
            retention = nil
            retentionLoaded = false
            queueRestored = true
            consecutiveFailures = 0
            retryNotBefore = nil
            openedSessionAt = nil
            sessionID = ""
            environment = nil
            drainClaim = nil
            droppedInOverflow = 0
            eraseGeneration &+= 1
        }
    }

    private let configuration: AethergramConfiguration
    private let transport: any SignalTransport
    private let queueStorage: any SignalQueueStorage
    private let retentionStore: any RetentionStore
    private let clientUserProvider: @Sendable () -> String?
    private let environmentProvider: @Sendable () -> [String: String]
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// How long the endpoint gets after the given run of failures.
    private let retryDelay: @Sendable (_ consecutiveFailures: Int) -> TimeInterval
    /// Serves a drain's delay. Throws when the drain is cancelled.
    private let sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void
    private let logger: Logger
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let waiters = FlushWaiters()

    /// The first line of every public entry point. A host seam called under
    /// the lock that calls back in would otherwise die inside the lock's own
    /// recursion check, frames away from the call that caused it; this names
    /// the entry point instead.
    private func requireNoReentry() {
        lock.precondition(.notOwner)
    }

    /// Whether a batch claimed at `generation` may still be acted on. Consent
    /// alone is not the question: `reset()` erases without moving the answer.
    private func permitsCollection(at generation: Int) -> Bool {
        lock.withLock { $0.gateOpen && $0.eraseGeneration == generation }
    }

    /// Mints a session identifier where consent permits and none is open. It
    /// only ever fills an empty slot: a session an erase dropped must not come
    /// back, and one already open must not be replaced under its own signals.
    private static func openSessionIfNeeded(_ state: inout State) {
        guard state.gateOpen, state.sessionID.isEmpty else { return }
        state.sessionID = UUID().uuidString
    }

    /// Opens and counts a session, unless this instance's own is open. Call
    /// from inside the lock, with the gate open.
    private func openCountedSession(_ current: inout State) {
        let started = now()
        loadRetentionIfNeeded(&current, at: started)
        // A session this instance already opened stays open. Two calls land
        // in one activation whenever consent is adopted from another device
        // — the host grants on that arrival, before the cycle's own session
        // emit — and without this the second call would close the first at
        // a near-zero duration and count the cycle twice.
        //
        // The comparison is against our own stamp, not merely against a
        // non-nil `openSessionStartedAt`: a session left open by a process
        // that died is also open, and closing that one is the entire point
        // of the inference path.
        if current.ownsOpenSession { return }
        current.openedSessionAt = started
        current.sessionID = UUID().uuidString
        let record = RetentionCounters.recordingSessionStart(
            in: current.retention,
            at: started,
            calendar: calendar
        )
        current.retention = record
        retentionStore.save(record)
    }

    /// The one place a signal becomes queued state. Everything the invariant
    /// forbids before consent — the payload read, the identifier, the disk
    /// write — sits behind the guard on the first line.
    private func enqueue(name: String, parameters: [String: String], floatValue: Double?) {
        let enqueued: (queued: Int, overflowBegan: Bool)? = lock.withLock { current in
            guard current.gateOpen else { return nil }
            restoreQueueIfNeeded(&current)
            let recordedAt = now()
            loadRetentionIfNeeded(&current, at: recordedAt)

            if current.environment == nil { current.environment = environmentProvider() }
            var merged = current.environment ?? [:]
            // The identity is stamped here rather than left to the provider,
            // because a host that overrides the environment would otherwise
            // drop the three fields every signal is promised to carry.
            merged.merge(Aethergram.parameters) { $1 }
            merged.merge(EnvironmentSnapshot.calendarParameters(at: recordedAt, calendar: calendar)) { $1 }
            merged.merge(
                RetentionCounters.parameters(from: current.retention, at: recordedAt, calendar: calendar)
            ) { $1 }
            // Consumer parameters win: the package's defaults are context, and
            // a caller that names the same key means the more specific thing.
            merged.merge(parameters) { $1 }
            // Only our own session's checkpoint moves. An inherited one closes
            // against the activity its own process last recorded, and moving
            // that to now would count the gap since the kill as use.
            if current.ownsOpenSession, let retention = current.retention {
                let touched = RetentionCounters.touching(retention, at: recordedAt)
                current.retention = touched.record
                // Saved under the lock that produced it: a record computed here
                // and saved after the release can land behind a concurrent
                // `clear()` and restore counters an erase dropped.
                if touched.shouldPersist { retentionStore.save(touched.record) }
            }
            // Stamped at record time rather than at send: a signal restored
            // after a kill would otherwise leave under a session that opened
            // after it happened. Never empty while the gate is open — a grant
            // and a reset both mint one.
            current.pending.append(
                Signal(
                    name: name,
                    parameters: merged,
                    floatValue: floatValue,
                    sessionID: current.sessionID,
                    recordedAt: recordedAt
                )
            )
            var overflow = 0
            var overflowBegan = false
            if current.pending.count > configuration.queueLimit {
                overflow = current.pending.count - configuration.queueLimit
                current.pending.removeFirst(overflow)
                current.evictedFromFront &+= overflow
                current.dequeuedFromFront &+= overflow
                overflowBegan = current.droppedInOverflow == 0
                current.droppedInOverflow &+= overflow
            }
            // Submitted under the same lock that produced it, which is what
            // makes the order writes land in the order the mutations committed.
            // The encode and the atomic write happen on the writer's serial
            // queue, off this thread. Not every O(queue) cost goes with them:
            // the snapshot shares this array's storage, so the next append or
            // eviction while the writer still holds it copies the whole queue
            // here, under the lock.
            let checkpoint = writer.persist(current.pending)
            if overflow > 0 { settleWaiters(current, removal: checkpoint) }
            return (current.pending.count, overflowBegan)
        }
        waiters.resumeSettled(writer: writer)
        guard let enqueued else {
            logger.debug("record skip consent-withheld")
            return
        }
        // Once on the way in, not per record: a queue stays full for as long
        // as the device is offline, and every emit in that stretch would
        // otherwise persist an error line.
        if enqueued.overflowBegan {
            logger.error("queue overflow began limit=\(self.configuration.queueLimit) dropping=oldest")
        }
        logger.debug("record ok name=\(name, privacy: .public) queued=\(enqueued.queued)")
        // A full batch goes now; anything less coalesces, so a burst of signals
        // costs one POST rather than one each. Without this the only drain was
        // the consumer's resign-time flush, and an app extension is suspended
        // moments after resigning — so nothing ever actually left the device.
        startDrain(after: configuration.deliveryDelay(queued: enqueued.queued))
    }

    /// One transmission attempt. Returns whether another batch should follow
    /// immediately, so `drain` stays a loop over a single decision.
    private func sendNextBatch(claim: Int) async -> Bool {
        let claimed = nextBatch(claim: claim)
        waiters.resumeSettled(writer: writer)
        guard let claimed else { return false }
        // Last gate before the bytes leave. It narrows the window rather than
        // closing it: nothing in here can recall a request already handed to
        // the transport, so what it buys is that the answer is re-read at the
        // instant of handoff. A decline after that purges the queue behind it,
        // and nothing further follows.
        guard permitsCollection(at: claimed.generation) else { return false }
        let outcome = await transport.send(claimed.batch)
        defer { waiters.resumeSettled(writer: writer) }
        return apply(
            outcome,
            sent: claimed.batch.signals,
            generation: claimed.generation,
            evicted: claimed.evicted
        )
    }

    /// Claims the front of the queue, with the erase generation and the
    /// eviction count it was claimed under, so a verdict on it can be told from
    /// a verdict on the queue that replaced it and from one on a queue an
    /// overflow has since shortened.
    ///
    /// The identifier is resolved in here rather than by the caller: outside
    /// the lock, a decline landing between the consent check and the read would
    /// let the host mint one while the answer is withheld.
    ///
    /// A drain whose claim an erase took claims nothing more. Without that,
    /// one that got past its last verdict before the erase would come back
    /// for the new queue's front alongside the drain that now owns it, and
    /// the same batch would go out twice.
    private func nextBatch(claim: Int) -> (batch: SignalBatch, generation: Int, evicted: Int)? {
        lock.withLock { current -> (batch: SignalBatch, generation: Int, evicted: Int)? in
            guard current.gateOpen, current.drainClaim == claim else { return nil }
            restoreQueueIfNeeded(&current)
            guard !current.pending.isEmpty else { return nil }
            guard let clientUser = clientUserProvider() else {
                // Counted as a failure so the capped backoff damps the retry:
                // a host that never resolves an identifier would otherwise be
                // woken at the steady interval for the life of the process.
                // Owed like any other failure, or a flush would ask the host
                // for an identifier it has already said it does not have, as
                // often as the consumer flushes.
                current.consecutiveFailures += 1
                current.failedAttempts &+= 1
                Self.oweRetry(&current, after: retryDelay(current.consecutiveFailures))
                settleWaiters(current, removal: nil)
                logger.error("drain halt reason=no-client-user")
                return nil
            }
            let batch = SignalBatch(
                signals: Array(current.pending.prefix(configuration.batchSize)),
                clientUser: clientUser
            )
            return (batch, current.eraseGeneration, current.evictedFromFront)
        }
    }

    /// Applies a transport verdict to the queue. Delivered and permanently
    /// rejected batches both leave it: a batch the server will keep refusing is
    /// not worth a retry slot forever.
    private func apply(_ outcome: TransportOutcome, sent: [Signal], generation: Int, evicted: Int) -> Bool {
        // Submitted under the same lock that mutated the queue, matching
        // `enqueue`: persisting after releasing the lock let a concurrent
        // enqueue's own in-lock persist land first, then get clobbered by
        // this stale (already-drained) snapshot arriving after it, silently
        // dropping the newly enqueued signal from durable storage.
        let applied: (keepDraining: Bool, overflowDropped: Int)? = lock.withLock { current in
            // A verdict on a batch an erase has since dropped applies to
            // nothing: the queue it indexed no longer exists, and its removal
            // would take the front off one recorded under a later grant.
            guard current.gateOpen, current.eraseGeneration == generation else { return nil }
            switch outcome {
            case .delivered, .permanent:
                // An overflow eviction during the send already dropped part of
                // what was sent, and the rest is still at the front. Counting
                // is what tells those apart: signals recorded alike are equal,
                // so matching the queue against the batch by value would take
                // the signal that replaced one it removes.
                let evictedSinceClaim = current.evictedFromFront &- evicted
                let removed = max(0, sent.count - evictedSinceClaim)
                current.pending.removeFirst(removed)
                current.dequeuedFromFront &+= removed
                current.consecutiveFailures = 0
                current.retryNotBefore = nil
                // The checkpoint's own ticket, not a later one: a flush waits
                // for this removal to reach the store and for nothing
                // recorded since.
                let checkpoint = writer.persist(current.pending)
                settleWaiters(current, removal: checkpoint)
                var overflowDropped = 0
                if current.pending.count < configuration.queueLimit {
                    overflowDropped = current.droppedInOverflow
                    current.droppedInOverflow = 0
                }
                return (!current.pending.isEmpty, overflowDropped)
            case .retryable:
                current.consecutiveFailures += 1
                current.failedAttempts &+= 1
                Self.oweRetry(&current, after: retryDelay(current.consecutiveFailures))
                settleWaiters(current, removal: nil)
                return (false, 0)
            case let .retryableAfter(_, delay):
                current.consecutiveFailures += 1
                current.failedAttempts &+= 1
                Self.oweRetry(&current, after: max(
                    retryDelay(current.consecutiveFailures),
                    Self.servableDelay(delay)
                ))
                settleWaiters(current, removal: nil)
                return (false, 0)
            }
        }
        guard let applied else {
            logger.info("send outcome discarded count=\(sent.count) reason=erased")
            return false
        }
        if applied.overflowDropped > 0 {
            logger.info("queue overflow ended dropped=\(applied.overflowDropped)")
        }
        let keepDraining = applied.keepDraining
        switch outcome {
        case .delivered:
            logger.info("send ok count=\(sent.count)")
        case let .permanent(reason):
            logger.error("send dropped count=\(sent.count) reason=\(reason, privacy: .public)")
        case let .retryable(reason), let .retryableAfter(reason, _):
            logger.info("send retry count=\(sent.count) reason=\(reason, privacy: .public)")
        }
        return keepDraining
    }

    /// Drops everything collected under the grant, in memory and on disk, in
    /// one lock section.
    ///
    /// The durable half cannot be left until after the release. A `record`
    /// landing in between — a reset keeps consent granted, so nothing stops one
    /// — persists its queue and saves its counters under the new generation,
    /// and this older purge and clear then delete them. Submitting the purge
    /// here orders it first: the writer keeps it pending under any snapshot
    /// submitted after it and runs it before the newest snapshot, and the
    /// store keeps only the newest write.
    private func eraseCollected(_ state: inout State) {
        state.eraseCollected()
        writer.purge()
        retentionStore.clear()
        settleWaiters(state, removal: nil)
    }

    /// The one part of an erase that cannot happen under the lock. The delete
    /// has to land before the caller returns: a recorder torn down in the same
    /// breath as a decline would otherwise leave the file behind. Waits until
    /// every write submitted before it, the purge included, has reached the
    /// store. A write submitted after it — a record on another thread, after
    /// a reset that leaves the gate open — is not promised by the return, and
    /// lengthens the wait by at most one store call.
    private func awaitErasure() {
        writer.waitForPendingWrites()
    }

    /// Reads the durable queue back at most once per recorder: an erase leaves
    /// it read, so a regrant cannot restore what the erase was told to drop.
    /// Signals persisted by a process the OS killed rejoin the front of the
    /// pending set, ahead of anything this process has recorded, so order
    /// survives the kill.
    private func restoreQueueIfNeeded(_ state: inout State) {
        guard !state.queueRestored else { return }
        state.queueRestored = true
        state.pending.insert(contentsOf: queueStorage.load(), at: 0)
        guard state.pending.count > configuration.queueLimit else { return }
        // Oldest-first, matching enqueue's eviction: a queue file written under
        // a higher limit must not transmit past the cap now in force.
        let overflow = state.pending.count - configuration.queueLimit
        state.pending.removeFirst(overflow)
        state.dequeuedFromFront &+= overflow
        logger.error("restore overflow dropped=\(overflow)")
        settleWaiters(state, removal: writer.persist(state.pending))
    }

    /// Day strings are converted here, once per load, rather than on every
    /// signal: a record from before 0.3.2 holds the device's own numbering,
    /// and reading it back costs calendar work per day. The converted record
    /// is what the next save persists.
    private func loadRetentionIfNeeded(_ state: inout State, at date: Date) {
        guard !state.retentionLoaded else { return }
        state.retentionLoaded = true
        state.retention = retentionStore.load().map {
            RetentionCounters.convertingDaysToGregorian(in: $0, at: date, calendar: calendar)
        }
    }

    /// Starts the one owned drain, or lets an existing one stand.
    ///
    /// A zero delay means "send now" and is the only thing that hurries a drain
    /// still waiting out its interval; the waiting task is cancelled and
    /// replaced. A running drain always stands, because delivery is already
    /// happening and a second task would duplicate the batch.
    ///
    /// What a zero delay cannot do is skip a retry the last failure owes. A
    /// flush and a full batch both ask for one, and both happen on the
    /// consumer's cadence rather than the endpoint's, so a backoff any of them
    /// could collapse would only damp a queue nobody was recording into.
    ///
    /// Cancellation is deliberate and safe: a cancelled send throws through
    /// `URLSession` as a retryable failure, so the batch stays queued and on
    /// disk. That is the same guarantee the durable queue gives when the OS
    /// kills the process outright, which is why an interrupted flush loses
    /// nothing.
    ///
    private func startDrain(after delay: TimeInterval) {
        lock.withLock { decideDrain(&$0, after: delay) }?.cancel()
    }

    /// `startDrain`'s decision, for a caller already inside the lock. Returns
    /// the waiting task it pre-empted, to be cancelled outside the lock.
    ///
    /// The task is created inside the claim, so the slot never holds a
    /// half-state and there is no late "still ours?" assignment to guard.
    private func decideDrain(_ current: inout State, after delay: TimeInterval) -> Task<Void, Never>? {
        guard current.gateOpen else { return nil }
        let due = max(delay, Self.secondsOwed(current.retryNotBefore))
        switch current.drain {
        case .running:
            return nil
        case let .waiting(existing):
            guard due == 0 else { return nil }
            current.drain = .running(makeOwnedDrain(&current, after: 0, waiting: false))
            return existing.task
        case .idle:
            let owned = makeOwnedDrain(&current, after: due, waiting: due > 0)
            current.drain = due > 0 ? .waiting(owned) : .running(owned)
            return nil
        }
    }

    /// The locked half of an awaited flush's call: notes what it waits for,
    /// or settles it at once, and starts or joins a drain. Returns the
    /// waiting task a zero-delay drain pre-empted.
    private func beginAttempt(_ id: UInt64, _ current: inout State) -> Task<Void, Never>? {
        guard current.gateOpen, !current.pending.isEmpty,
              Self.secondsOwed(current.retryNotBefore) == 0 else {
            waiters.settleNow(id)
            return nil
        }
        let target = FlushWaiters.Target(
            generation: current.eraseGeneration,
            dequeued: current.dequeuedFromFront &+ current.pending.count,
            failedAttempts: current.failedAttempts
        )
        guard waiters.aim(id, at: target) else { return nil }
        return decideDrain(&current, after: 0)
    }

    /// Settles every awaited flush `state` answers. Call from inside the
    /// lock section that produced `state`, with the ticket of the checkpoint
    /// that section submitted for a removal, so a flush waits for that write
    /// and no later one.
    private func settleWaiters(_ state: State, removal: QueueWriter.Ticket?) {
        waiters.settle(
            FlushWaiters.Progress(
                gateOpen: state.gateOpen,
                generation: state.eraseGeneration,
                dequeued: state.dequeuedFromFront,
                failedAttempts: state.failedAttempts
            ),
            removal: removal
        )
    }

    /// A backend's delay as one a sleep can serve. Bounded at the interval
    /// ceiling, because a sleep traps past about 9.2e18 seconds and one
    /// header is all it takes; a NaN or a past delay asks for no wait, so it
    /// owes what the backoff owes.
    private static func servableDelay(_ delay: TimeInterval) -> TimeInterval {
        guard delay > 0 else { return 0 }
        return min(delay, AethergramConfiguration.maximumInterval)
    }

    /// Records what the next attempt owes the endpoint. Call from inside the
    /// lock.
    private static func oweRetry(_ state: inout State, after interval: TimeInterval) {
        state.retryNotBefore = ContinuousClock.now.advanced(by: .seconds(interval))
    }

    /// Seconds still owed, and zero once the deadline is served or was never
    /// set — so the caller can take the later of it and its own delay.
    private static func secondsOwed(_ deadline: ContinuousClock.Instant?) -> TimeInterval {
        guard let deadline else { return 0 }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(remaining.seconds) + Double(remaining.attoseconds) * 1e-18)
    }

    /// Mints the identifier and the task together, so a task always knows the
    /// name the slot holds it under. Call from inside the lock, and install
    /// the task as `.waiting` exactly when `waiting` is true.
    private func makeOwnedDrain(_ state: inout State, after delay: TimeInterval, waiting: Bool) -> OwnedDrain {
        state.lastDrainID &+= 1
        let id = state.lastDrainID
        return OwnedDrain(id: id, task: makeDrainTask(id: id, after: delay, promoting: waiting))
    }

    /// Utility, matching the writer queue, rather than inherited: most records
    /// come from the main actor, and a drain at its priority would put the
    /// encode and the request in contention with the host's UI.
    ///
    /// Holds the recorder weakly until it starts sending, so a released
    /// recorder is not kept alive by a drain that has not started; `deinit`
    /// cancels that drain. From the promotion on it holds the recorder
    /// strongly, through its whole pass: a recorder released mid-send still
    /// sends the rest of what that pass finds queued, and nothing after,
    /// because the drain its release schedules starts out waiting.
    private func makeDrainTask(id: Int, after delay: TimeInterval, promoting: Bool) -> Task<Void, Never> {
        Task(priority: .utility) { [weak self, sleep] in
            if delay > 0 {
                do {
                    try await sleep(delay)
                } catch {
                    // Pre-empted or torn down. The canceller already took the
                    // slot, so releasing it here would evict the live drain
                    // that replaced this one.
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            if promoting, !promoteWaitingDrain(id: id) { return }
            await drain()
            releaseDrainSlot(id: id)
        }
    }

    /// The delay is served; from here the task cannot be hurried, only awaited.
    ///
    /// False when the slot moved on while this one slept. Draining anyway would
    /// take the claim from the live drain and hold it for a whole
    /// transmission, so the replacement wakes to find a queue it cannot claim.
    private func promoteWaitingDrain(id: Int) -> Bool {
        lock.withLock { current in
            guard case let .waiting(owned) = current.drain, owned.id == id else { return false }
            current.drain = .running(owned)
            return true
        }
    }

    /// Gives the slot back and decides the next drain in the same lock section.
    ///
    /// Both halves have to happen here. A record that landed while this drain
    /// was running found the slot taken and scheduled nothing, so anything
    /// still queued now has nobody coming for it: deciding after the release
    /// would leave the same gap one lock section wide. And only the task the
    /// slot still holds may free it — a cancelled or superseded one would
    /// evict the drain that replaced it.
    private func releaseDrainSlot(id: Int) {
        lock.withLock { current in
            guard current.drain.owned?.id == id else { return }
            current.drain = .idle
            guard current.gateOpen, !current.pending.isEmpty else { return }
            // The steady interval when nothing failed, and what the failure
            // owes when something did: the jittered draw, or the backend's
            // own delay where that is later. Recomputing a backoff here would
            // hand every install the same deterministic ceiling again.
            //
            // A registered flush waits on this drain, so it is not held a
            // whole interval: it restarts at once, or when the retry is owed.
            let delay = current.consecutiveFailures == 0 && waiters.count == 0
                ? configuration.transmitInterval
                : Self.secondsOwed(current.retryNotBefore)
            // Waiting even at zero delay, so the task promotes through a
            // weak reference that a released recorder's `deinit` has
            // cancelled first.
            current.drain = .waiting(makeOwnedDrain(&current, after: delay, waiting: true))
        }
    }

    /// Gives the slot up and hands the task back to be cancelled outside the
    /// lock. Call from inside the erase that supersedes it.
    ///
    /// Both halves of that matter. Releasing the slot in the same section as
    /// the erase is what lets a record landing immediately after schedule a
    /// drain of its own: a slot still held across that seam takes the record's
    /// schedule — `startDrain` stands down for a drain already owned — and the
    /// cancel that follows then takes the drain it stood down for, leaving a
    /// signal queued with nothing coming for it. And the cancel stays outside,
    /// because cancelling under the lock would run a cancellation handler on
    /// this thread with the lock held.
    private static func detachOwnedDrain(_ state: inout State) -> Task<Void, Never>? {
        let owned = state.drain.owned
        state.drain = .idle
        return owned?.task
    }
}

/// The awaited flushes waiting on the recorder, under a lock of their own.
///
/// Apart from the recorder's lock so a cancel never takes that one: a
/// restore or an identifier resolution can hold it for as long as the host
/// takes, and a cancelled flush has to return regardless. The recorder takes
/// this lock inside its own, never the reverse, and nothing here calls out
/// while holding it.
private final class FlushWaiters: Sendable {
    // MARK: Internal

    /// What a flush waits for, noted at its call: the erase generation, the
    /// front count at which everything queued then has left, and the failed
    /// attempts so far.
    struct Target {
        let generation: Int
        let dequeued: Int
        let failedAttempts: Int
    }

    /// The recorder's state as far as a flush can tell, read in the lock
    /// section that changed it.
    struct Progress {
        let gateOpen: Bool
        let generation: Int
        let dequeued: Int
        let failedAttempts: Int
    }

    var count: Int {
        state.withLock { $0.entries.count }
    }

    func mint() -> UInt64 {
        state.withLock { state in
            state.lastID &+= 1
            return state.lastID
        }
    }

    func arm(_ id: UInt64, _ continuation: CheckedContinuation<Void, Never>) {
        state.withLock { $0.entries[id] = Entry(continuation: continuation) }
    }

    /// Removes the waiter and resumes it. Idempotent, so a cancel and a
    /// settle can both reach it.
    func resume(_ id: UInt64) {
        state.withLock { $0.entries.removeValue(forKey: id) }?.continuation.resume()
    }

    /// Gives a registered waiter its target. False when it is gone, so the
    /// caller starts no drain for a flush nobody is waiting on.
    func aim(_ id: UInt64, at target: Target) -> Bool {
        state.withLock { state in
            guard state.entries[id] != nil else { return false }
            state.entries[id]?.target = target
            return true
        }
    }

    /// Readies a waiter to return without waiting for anything.
    func settleNow(_ id: UInt64) {
        state.withLock { state in
            guard state.entries[id] != nil else { return }
            state.entries[id]?.target = nil
            state.ready.append((id, nil))
        }
    }

    /// Readies every aimed waiter `progress` answers. One whose signals have
    /// all left the queue waits for `removal` to land first.
    func settle(_ progress: Progress, removal: QueueWriter.Ticket?) {
        state.withLock { state in
            for (id, entry) in state.entries {
                guard let target = entry.target else { continue }
                let erasedOrFailed = !progress.gateOpen
                    || progress.generation != target.generation
                    || progress.failedAttempts != target.failedAttempts
                let left = progress.dequeued &- target.dequeued >= 0
                guard erasedOrFailed || left else { continue }
                state.entries[id]?.target = nil
                state.ready.append((id, erasedOrFailed ? nil : removal))
            }
        }
    }

    /// Returns the waiters settled so far: at once, or once their removal
    /// has landed. Call outside the recorder's lock, after any section that
    /// can settle one.
    func resumeSettled(writer: QueueWriter) {
        let ready = state.withLock { state in
            defer { state.ready = [] }
            return state.ready
        }
        for (id, removal) in ready {
            guard let removal else {
                resume(id)
                continue
            }
            Task(priority: .utility) { [self] in
                await writer.awaitWrites(through: removal)
                resume(id)
            }
        }
    }

    // MARK: Private

    private struct Entry {
        let continuation: CheckedContinuation<Void, Never>
        /// Nil until the call is noted, and again once settled.
        var target: Target?
    }

    private struct State {
        var lastID: UInt64 = 0
        var entries: [UInt64: Entry] = [:]
        var ready: [(id: UInt64, removal: QueueWriter.Ticket?)] = []
    }

    private let state = Mutex(State())
}

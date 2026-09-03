import Foundation
import os

/// The package's one entry point: consent gate, durable queue, batching,
/// backoff, and the retention counters, over a transport it knows nothing
/// about.
///
/// **Consent is the invariant, not a filter.** Until `updateConsent(.granted)`
/// lands, `record` allocates nothing, writes nothing, resolves no identifier,
/// advances no counter, and reaches no transport; a later decline purges the
/// queue and the counters rather than merely stopping new writes. Every one of
/// those clauses is asserted in `ConsentEnforcementTests`, because a
/// transport-only assertion cannot tell "dropped before enqueue" from
/// "enqueued but not yet sent", and only the first is what consent requires.
///
/// **Recording is synchronous and never throws.** Consumers emit from view
/// code and lifecycle hooks; a call that could suspend would change every call
/// site and a call that could fail would put error handling on paths that have
/// nothing useful to do with the error. Transmission is the async half, and it
/// is the only half.
public final class SignalRecorder: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - clientUserProvider: Resolves the consumer's analytics identifier.
    ///     Called only on a transmit that consent already permits, so an
    ///     implementation that mints and persists an identifier on first read
    ///     cannot plant one before the answer.
    ///   - environmentProvider: The authored default payload. Called at most
    ///     once, on the first permitted record, for the same reason.
    public init(
        configuration: AethergramConfiguration,
        transport: any SignalTransport,
        queueStorage: any SignalQueueStorage,
        retentionStore: any RetentionStore,
        clientUserProvider: @escaping @Sendable () -> String?,
        environmentProvider: @escaping @Sendable () -> [String: String] = { EnvironmentSnapshot.current().parameters },
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.queueStorage = queueStorage
        writer = QueueWriter(storage: queueStorage, label: "\(configuration.logSubsystem).aethergram-queue-writer")
        self.retentionStore = retentionStore
        self.clientUserProvider = clientUserProvider
        self.environmentProvider = environmentProvider
        self.calendar = calendar
        self.now = now
        logger = Logger(subsystem: configuration.logSubsystem, category: "aethergram")
    }

    // MARK: Public

    /// Adopts the consumer's consent answer. Granting only opens the gate;
    /// anything other than granted closes it *and* erases what was collected
    /// under it — the queue file, the retention counters, and the pending
    /// batch — because a toggle that leaves yesterday's signals on disk to be
    /// sent later is not an off switch.
    public func updateConsent(_ state: ConsentState) {
        let erase: Bool = lock.withLock { current in
            current.consent = state
            guard !state.permitsCollection else {
                if current.sessionID.isEmpty { current.sessionID = UUID().uuidString }
                return false
            }
            current.eraseCollected()
            return true
        }
        guard erase else {
            logger.info("consent granted")
            return
        }
        cancelOwnedDrain()
        eraseDurableState()
        logger.info("consent withheld state=\(state.rawValue, privacy: .public) queue purged")
    }

    /// Records a consumer signal. The configured prefix is applied here.
    public func record(_ name: String, parameters: [String: String] = [:], floatValue: Double? = nil) {
        enqueue(name: configuration.signalPrefix + name, parameters: parameters, floatValue: floatValue)
    }

    /// Records the purchase preset. Unprefixed: the name is the package's, and
    /// each adapter maps it onto its vendor's own purchase event.
    public func recordPurchaseCompleted(_ details: PurchaseDetails, parameters: [String: String] = [:]) {
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
    /// not the caller-wins rule `enqueue` applies to package defaults: this key
    /// carries the signal's identity and arrives through its own argument, so a
    /// stray dictionary entry under the same name is a mistake rather than a
    /// more specific value.
    public func recordError(id: String, parameters: [String: String] = [:]) {
        var combined = parameters
        combined[PayloadKey.errorID] = id
        enqueue(name: PresetSignal.errorOccurred.rawValue, parameters: combined, floatValue: nil)
    }

    /// Opens a session for the counters. A session boundary is host-specific —
    /// a short-lived extension process has no app foreground to key off — so
    /// the host calls it and the package counts.
    public func beginSession() {
        let record: RetentionRecord? = lock.withLock { current -> RetentionRecord? in
            guard current.consent.permitsCollection else { return nil }
            loadRetentionIfNeeded(&current)
            // A session this instance already opened stays open. Two calls land
            // in one activation whenever consent is adopted from another device
            // — `reconcileSyncedPreferences` grants before the cycle's own
            // session emit — and without this the second call would close the
            // first at a near-zero duration and count the cycle twice.
            //
            // The comparison is against our own stamp, not merely against a
            // non-nil `openSessionStartedAt`: a session left open by a process
            // that died is also open, and closing that one is the entire point
            // of the inference path.
            if let ours = current.openedSessionAt, current.retention?.openSessionStartedAt == ours {
                return nil
            }
            let started = now()
            current.openedSessionAt = started
            current.sessionID = UUID().uuidString
            current.retention = RetentionCounters.recordingSessionStart(
                in: current.retention,
                at: started,
                calendar: calendar
            )
            return current.retention
        }
        guard let record else { return }
        retentionStore.save(record)
    }

    /// Closes the session opened by `beginSession()` and folds its duration
    /// into the averages.
    public func endSession() {
        let record: RetentionRecord? = lock.withLock { current -> RetentionRecord? in
            guard current.consent.permitsCollection, let existing = current.retention else { return nil }
            current.openedSessionAt = nil
            current.retention = RetentionCounters.recordingSessionEnd(in: existing, at: now())
            return current.retention
        }
        guard let record else { return }
        retentionStore.save(record)
    }

    /// Best-effort send now. Called on the consumer's deactivation hook, where
    /// the process may not survive long enough to finish — which is why the
    /// queue is durable rather than why this call blocks.
    public func flush() {
        // The consumer calls this on its way out of an active cycle, which is
        // the one moment a not-yet-written queue would be lost rather than
        // merely late. Bounded by a single encode and write.
        writer.waitForPendingWrites()
        startDrain(after: 0)
    }

    /// Erases everything the package persists. Wire it into the host's
    /// data-reset path: this is what makes the retention counters clearable,
    /// which the SDK this replaces offered no way to do.
    public func reset() {
        lock.withLock { $0.eraseCollected() }
        cancelOwnedDrain()
        eraseDurableState()
        logger.info("reset ok")
    }

    // MARK: Internal

    /// Every mutation of the durable queue goes through here, never through
    /// `queueStorage` directly; `load()` is the one read and stays direct.
    ///
    /// Internal rather than private so a test can wait on the same writes
    /// `flush()` waits on. Both the property and `waitForPendingWrites()` have
    /// production callers, so this widens visibility without adding surface
    /// that exists only for tests.
    let writer: QueueWriter

    /// Sends queued signals until the queue empties or a send fails. Internal
    /// rather than public so tests can await a transmission the consumer only
    /// ever kicks off; `flush()` is the consumer's door.
    func drain() async {
        let claimed: Bool = lock.withLock { current in
            guard !current.isDraining else { return false }
            current.isDraining = true
            return true
        }
        guard claimed else { return }
        defer { lock.withLock { $0.isDraining = false } }
        while await sendNextBatch() {}
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
        case waiting(Task<Void, Never>)
        case running(Task<Void, Never>)
    }

    private struct State {
        var consent: ConsentState = .neverAsked
        var pending: [Signal] = []
        var environment: [String: String]?
        var retention: RetentionRecord?
        var retentionLoaded = false
        var queueRestored = false
        var isDraining = false
        /// At most one drain is owned at a time, and the slot says which of
        /// the three states it is in rather than leaving that to be inferred
        /// from a pair of flags and an optional.
        var drain: DrainSlot = .idle
        var consecutiveFailures = 0
        var sessionID = ""
        /// The start this instance stamped on the session it opened, so a
        /// repeat `beginSession()` in the same activation can be told apart
        /// from one that inherits a dead process's open session.
        var openedSessionAt: Date?

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
        mutating func eraseCollected() {
            pending = []
            retention = nil
            retentionLoaded = false
            queueRestored = true
            consecutiveFailures = 0
            openedSessionAt = nil
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
    private let logger: Logger
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private var permitsCollection: Bool {
        lock.withLock { $0.consent.permitsCollection }
    }

    /// The one place a signal becomes queued state. Everything the invariant
    /// forbids before consent — the payload read, the identifier, the disk
    /// write — sits behind the guard on the first line.
    private func enqueue(name: String, parameters: [String: String], floatValue: Double?) {
        // The retention record rides out of the lock rather than being saved
        // inside it: a `UserDefaults` write under a spin lock is the shape the
        // queue writer exists to avoid.
        let outcome: (snapshot: [Signal], retentionToSave: RetentionRecord?)? = lock.withLock { current in
            guard current.consent.permitsCollection else { return nil }
            var retentionToSave: RetentionRecord?
            restoreQueueIfNeeded(&current)
            loadRetentionIfNeeded(&current)

            if current.environment == nil { current.environment = environmentProvider() }
            let recordedAt = now()
            var merged = current.environment ?? [:]
            merged.merge(EnvironmentSnapshot.calendarParameters(at: recordedAt, calendar: calendar)) { $1 }
            merged.merge(
                RetentionCounters.parameters(from: current.retention, at: recordedAt, calendar: calendar)
            ) { $1 }
            // Consumer parameters win: the package's defaults are context, and
            // a caller that names the same key means the more specific thing.
            merged.merge(parameters) { $1 }
            if let retention = current.retention {
                let touched = RetentionCounters.touching(retention, at: recordedAt)
                current.retention = touched.record
                if touched.shouldPersist { retentionToSave = touched.record }
            }
            current.pending.append(
                Signal(name: name, parameters: merged, floatValue: floatValue, recordedAt: recordedAt)
            )
            if current.pending.count > configuration.queueLimit {
                let overflow = current.pending.count - configuration.queueLimit
                current.pending.removeFirst(overflow)
                logger.error("queue overflow dropped=\(overflow)")
            }
            // Submitted under the same lock that produced it, which is what
            // makes the order writes land in the order the mutations committed.
            // The encode and the atomic write happen on the writer's serial
            // queue, off this thread — most call sites are the main actor, and
            // rewriting the whole queue there is O(queue) at every emit.
            writer.persist(current.pending)
            return (current.pending, retentionToSave)
        }
        guard let outcome else {
            logger.debug("record skip consent-withheld")
            return
        }
        if let retentionToSave = outcome.retentionToSave { retentionStore.save(retentionToSave) }
        let snapshot = outcome.snapshot
        logger.debug("record ok name=\(name, privacy: .public) queued=\(snapshot.count)")
        // A full batch goes now; anything less coalesces, so a burst of signals
        // costs one POST rather than one each. Without this the only drain was
        // the consumer's resign-time flush, and an app extension is suspended
        // moments after resigning — so nothing ever actually left the device.
        startDrain(after: configuration.deliveryDelay(queued: snapshot.count))
    }

    /// One transmission attempt. Returns whether another batch should follow
    /// immediately, so `drain` stays a loop over a single decision.
    private func sendNextBatch() async -> Bool {
        let hasWork: Bool = lock.withLock { current in
            guard current.consent.permitsCollection else { return false }
            restoreQueueIfNeeded(&current)
            return !current.pending.isEmpty
        }
        guard hasWork else { return false }
        guard let clientUser = clientUserProvider() else {
            logger.error("drain halt reason=no-client-user")
            return false
        }
        guard let batch = nextBatch(clientUser: clientUser) else { return false }
        // Last gate before the bytes leave. A decline landing after this point
        // cannot recall a request already handed to the transport; it purges
        // the queue behind it, so nothing further follows.
        guard permitsCollection else { return false }
        let outcome = await transport.send(batch)
        return apply(outcome, sent: batch.signals)
    }

    private func nextBatch(clientUser: String) -> SignalBatch? {
        lock.withLock { current in
            guard current.consent.permitsCollection, !current.pending.isEmpty else { return nil }
            return SignalBatch(
                signals: Array(current.pending.prefix(configuration.batchSize)),
                clientUser: clientUser,
                sessionID: current.sessionID
            )
        }
    }

    /// Applies a transport verdict to the queue. Delivered and permanently
    /// rejected batches both leave it: a batch the server will keep refusing is
    /// not worth a retry slot forever.
    private func apply(_ outcome: TransportOutcome, sent: [Signal]) -> Bool {
        // Submitted under the same lock that mutated the queue, matching
        // `enqueue`: persisting after releasing the lock let a concurrent
        // enqueue's own in-lock persist land first, then get clobbered by
        // this stale (already-drained) snapshot arriving after it, silently
        // dropping the newly enqueued signal from durable storage.
        let keepDraining = lock.withLock { current -> Bool in
            switch outcome {
            case .delivered, .permanent:
                // Removes only when the queue still starts with the sent
                // signals: a concurrent overflow eviction or drain can shift
                // the front first, and blindly removing here would discard
                // signals that were never actually sent.
                if current.pending.starts(with: sent) {
                    current.pending.removeFirst(sent.count)
                }
                current.consecutiveFailures = 0
                writer.persist(current.pending)
                return !current.pending.isEmpty
            case .retryable:
                current.consecutiveFailures += 1
                return false
            }
        }
        switch outcome {
        case .delivered:
            logger.info("send ok count=\(sent.count)")
        case let .permanent(reason):
            logger.error("send dropped count=\(sent.count) reason=\(reason, privacy: .public)")
        case let .retryable(reason):
            logger.info("send retry count=\(sent.count) reason=\(reason, privacy: .public)")
        }
        return keepDraining
    }

    /// The out-of-lock half of an erase: the durable copies of everything
    /// `eraseCollected` dropped from memory.
    private func eraseDurableState() {
        writer.purge()
        retentionStore.clear()
    }

    /// Reads the durable queue back exactly once per grant. Signals persisted
    /// by a process the OS killed rejoin the front of the pending set,
    /// ahead of anything this process has recorded, so order survives the kill.
    private func restoreQueueIfNeeded(_ state: inout State) {
        guard !state.queueRestored else { return }
        state.queueRestored = true
        state.pending.insert(contentsOf: queueStorage.load(), at: 0)
        guard state.pending.count > configuration.queueLimit else { return }
        // Oldest-first, matching enqueue's eviction: a queue file written under
        // a higher limit must not transmit past the cap now in force.
        let overflow = state.pending.count - configuration.queueLimit
        state.pending.removeFirst(overflow)
        logger.error("restore overflow dropped=\(overflow)")
        writer.persist(state.pending)
    }

    private func loadRetentionIfNeeded(_ state: inout State) {
        guard !state.retentionLoaded else { return }
        state.retentionLoaded = true
        state.retention = retentionStore.load()
    }

    /// Starts the one owned drain, or lets an existing one stand.
    ///
    /// A zero delay means "send now" and is the only thing that hurries a drain
    /// still waiting out its interval; the waiting task is cancelled and
    /// replaced. A running drain always stands, because delivery is already
    /// happening and a second task would duplicate the batch.
    ///
    /// Cancellation is deliberate and safe: a cancelled send throws through
    /// `URLSession` as a retryable failure, so the batch stays queued and on
    /// disk. That is the same guarantee the durable queue gives when the OS
    /// kills the process outright, which is why an interrupted flush loses
    /// nothing.
    private func startDrain(after delay: TimeInterval) {
        // The task is created inside the claim, so the slot never holds a
        // half-state and there is no late "still ours?" assignment to guard.
        let preempted: Task<Void, Never>? = lock.withLock { current in
            guard current.consent.permitsCollection else { return nil }
            switch current.drain {
            case .running:
                return nil
            case let .waiting(existing):
                guard delay == 0 else { return nil }
                current.drain = .running(makeDrainTask(after: 0))
                return existing
            case .idle:
                let task = makeDrainTask(after: delay)
                current.drain = delay > 0 ? .waiting(task) : .running(task)
                return nil
            }
        }
        preempted?.cancel()
    }

    private func makeDrainTask(after delay: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    // Pre-empted or torn down. The canceller already took the
                    // slot, so releasing it here would evict the live drain
                    // that replaced this one.
                    return
                }
                self?.promoteWaitingDrain()
            }
            guard !Task.isCancelled, let self else { return }
            await drain()
            let retry = retryDelay()
            releaseDrainSlot()
            if let retry { startDrain(after: retry) }
        }
    }

    /// The delay is served; from here the task cannot be hurried, only awaited.
    private func promoteWaitingDrain() {
        lock.withLock { current in
            guard case let .waiting(task) = current.drain else { return }
            current.drain = .running(task)
        }
    }

    private func releaseDrainSlot() {
        lock.withLock { $0.drain = .idle }
    }

    private func cancelOwnedDrain() {
        let task: Task<Void, Never>? = lock.withLock { current in
            switch current.drain {
            case .idle:
                return nil
            case let .waiting(task), let .running(task):
                current.drain = .idle
                return task
            }
        }
        task?.cancel()
    }

    /// How long before trying again, or nil when there is nothing queued or
    /// nothing has failed.
    private func retryDelay() -> TimeInterval? {
        lock.withLock { current in
            guard !current.pending.isEmpty, current.consecutiveFailures > 0 else { return nil }
            return configuration.backoffInterval(consecutiveFailures: current.consecutiveFailures)
        }
    }
}

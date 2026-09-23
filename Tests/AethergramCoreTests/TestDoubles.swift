@testable import AethergramCore
import Foundation

/// The host subsystem the package logs under. A test supplies one because the
/// package deliberately owns no logging constant of its own.
let testLogSubsystem = "com.example.app.aethergram.tests"

/// Thread-safe call counter.
///
/// The consent invariant turns on *whether* a collaborator ran at all, not on
/// what it returned, so most of these assertions read a count rather than a
/// value. A lock rather than a bare `var` because the recorder hands its
/// closures to a transport that may run them off the test's task.
final class Counter: @unchecked Sendable {
    // MARK: Internal

    var count: Int {
        lock.withLock { value }
    }

    /// The consent assertions ask whether a collaborator ran at all, which is a
    /// different question from how often.
    var wasCalled: Bool {
        lock.withLock { value > 0 }
    }

    func increment() {
        lock.withLock { value += 1 }
    }

    /// Reads and advances in one critical section, so a stepping clock built
    /// on this never hands two callers the same instant.
    func nextIndex() -> Int {
        lock.withLock {
            let current = value
            value += 1
            return current
        }
    }

    // MARK: Private

    private let lock = NSLock()
    private var value = 0
}

/// A one-shot signal a test suspends on rather than blocks on.
///
/// The half that opens a gate is on a GCD thread — the writer's serial queue, a
/// `DispatchQueue.global()` block — and cannot suspend; the half that waits is a
/// test body on a cooperative thread, and a cooperative thread parked on a
/// semaphore is one the release can never be scheduled on. A finished stream
/// squares those: `open()` blocks nothing, and a `wait()` arriving after it
/// ends at once rather than waiting for a signal that already came.
///
/// `AsyncStream` rather than a bare continuation, because it resumes its
/// iterator when the waiting task is cancelled. A suite time limit cancels; a
/// task suspended on something that ignores cancellation is a hang the limit
/// cannot fail, which is the failure this whole type exists to make reportable.
/// One waiter per gate: the stream has a single consumer.
final class Gate: @unchecked Sendable {
    // MARK: Lifecycle

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    // MARK: Internal

    /// Whether the gate is open, without waiting for it. The bounded negative
    /// checks read this after a sleep, because "still shut" is not something a
    /// wait can express.
    var isOpen: Bool {
        lock.withLock { opened }
    }

    /// Set before the finish, so anything the wait releases reads the state
    /// that released it. Idempotent, as a signal nobody counts should be.
    func open() {
        lock.withLock { opened = true }
        continuation.finish()
    }

    /// Nothing is ever yielded: the finish is the whole signal, and a stream
    /// finished before the first iteration ends it immediately.
    func wait() async {
        for await _ in stream {}
    }

    // MARK: Private

    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var opened = false
}

/// Records every batch it is handed and answers from a scripted outcome list,
/// falling back to `defaultOutcome` once the script runs out.
final class SpyTransport: SignalTransport, @unchecked Sendable {
    // MARK: Lifecycle

    init(outcomes: [TransportOutcome] = [], defaultOutcome: TransportOutcome = .delivered) {
        scripted = outcomes
        self.defaultOutcome = defaultOutcome
    }

    // MARK: Internal

    var batches: [SignalBatch] {
        lock.withLock { received }
    }

    var sendCount: Int {
        lock.withLock { received.count }
    }

    /// Every signal across every batch, in the order the transport saw them.
    var sentSignalNames: [String] {
        lock.withLock { received.flatMap { $0.signals.map(\.name) } }
    }

    var sentSignals: [Signal] {
        lock.withLock { received.flatMap(\.signals) }
    }

    func send(_ batch: SignalBatch) async -> TransportOutcome {
        // A real transport suspends; yielding keeps the double honest about
        // the seam rather than resolving synchronously.
        await Task.yield()
        return lock.withLock {
            received.append(batch)
            guard !scripted.isEmpty else { return defaultOutcome }
            return scripted.removeFirst()
        }
    }

    // MARK: Private

    private let defaultOutcome: TransportOutcome
    private let lock = NSLock()
    private var scripted: [TransportOutcome]
    private var received: [SignalBatch] = []
}

/// Runs the test's own work while it holds a batch.
///
/// That is the window a real network call opens between the recorder claiming a
/// batch and applying the verdict on it, and it is where an erase does its
/// damage. A second thread would open the same window without being able to say
/// when, so the send waits for the work instead: the erase lands after the
/// claim and before the verdict, every run.
///
/// The work runs on a global queue rather than on the drain's own task because
/// it is usually a call back into the recorder that waits on the writer queue,
/// and a drain that parks its cooperative thread there is one thread fewer for
/// every other suspended test to resume onto.
final class MidSendTransport: SignalTransport, @unchecked Sendable {
    // MARK: Lifecycle

    init(outcome: TransportOutcome = .delivered) {
        self.outcome = outcome
    }

    // MARK: Internal

    /// Run once, inside the first `send`. Assigned after the recorder exists,
    /// because the work under test is usually a call back into it — which is
    /// also why the first send drops it: the closure holding the recorder that
    /// holds this transport is a cycle until it does.
    var duringFirstSend: (@Sendable () -> Void)? {
        get { lock.withLock { work } }
        set { lock.withLock { work = newValue } }
    }

    var batches: [SignalBatch] {
        lock.withLock { received }
    }

    var sendCount: Int {
        lock.withLock { received.count }
    }

    var sentSignals: [Signal] {
        lock.withLock { received.flatMap(\.signals) }
    }

    func send(_ batch: SignalBatch) async -> TransportOutcome {
        await Task.yield()
        let pending: (@Sendable () -> Void)? = lock.withLock {
            received.append(batch)
            let next = work
            work = nil
            return next
        }
        if let pending {
            let finished = Gate()
            DispatchQueue.global().async {
                pending()
                finished.open()
            }
            await finished.wait()
        }
        return outcome
    }

    // MARK: Private

    private let outcome: TransportOutcome
    private let lock = NSLock()
    private var work: (@Sendable () -> Void)?
    private var received: [SignalBatch] = []
}

/// In-memory queue storage that announces its purge and can be told to hold it
/// open until released.
///
/// The hold is what puts a test inside the window an erase's durable half
/// occupies, rather than timing it: a purge that waits is a purge the test can
/// act around, and a recorder that waits for the delete cannot return while it
/// is held.
///
/// The hold blocks the writer's serial queue, which is the GCD thread that
/// called `purge()`; the announcement is a gate, because what acts on it is a
/// test body the cooperative pool has to be free to resume.
final class GatedQueueStorage: SignalQueueStorage, @unchecked Sendable {
    // MARK: Internal

    /// Opened as `purge()` is entered, before it is held or takes effect.
    let purgeEntered = Gate()

    var isPurged: Bool {
        lock.withLock { purged }
    }

    var signals: [Signal] {
        lock.withLock { stored }
    }

    /// Makes the next `purge()` wait for `releasePurge()`.
    func holdPurge() {
        lock.withLock { held = true }
    }

    func releasePurge() {
        release.signal()
    }

    func load() -> [Signal] {
        lock.withLock { stored }
    }

    func persist(_ signals: [Signal]) {
        lock.withLock { stored = signals }
    }

    func purge() {
        purgeEntered.open()
        if lock.withLock({ held }) { release.wait() }
        lock.withLock {
            stored = []
            purged = true
        }
    }

    // MARK: Private

    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: [Signal] = []
    private var purged = false
    private var held = false
}

/// A `RetentionStore` that holds every `save` open until the test releases it,
/// and announces the clear.
///
/// A save held open is a save still in flight, which is the state the ordering
/// question is about: whether an erase can get past the recorder's lock while
/// one is outstanding. Announcing the clear is how the test finds out, without
/// waiting on a clock to tell it.
///
/// The hold blocks whichever GCD thread called `save`, as `GatedQueueStorage`
/// does; both announcements are gates for the same reason.
final class GatedRetentionStore: RetentionStore, @unchecked Sendable {
    // MARK: Internal

    /// Opened as `save` is entered, before it is held.
    let saveEntered = Gate()
    /// Opened once `clear` has taken effect.
    let cleared = Gate()

    var record: RetentionRecord? {
        lock.withLock { stored }
    }

    var saveCallCount: Int {
        lock.withLock { saveCalls }
    }

    func releaseSave() {
        release.signal()
    }

    func load() -> RetentionRecord? {
        lock.withLock { stored }
    }

    func save(_ record: RetentionRecord) {
        saveEntered.open()
        release.wait()
        lock.withLock {
            stored = record
            saveCalls += 1
        }
    }

    func clear() {
        lock.withLock { stored = nil }
        cleared.open()
    }

    // MARK: Private

    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: RetentionRecord?
    private var saveCalls = 0
}

/// In-memory `RetentionStore` that counts every call, so a test can tell
/// "no counter advanced" from "a counter advanced and was then cleared".
final class SpyRetentionStore: RetentionStore, @unchecked Sendable {
    // MARK: Lifecycle

    init(seed: RetentionRecord? = nil) {
        stored = seed
    }

    // MARK: Internal

    /// Run once, inside the `clear` an erase performs — which the recorder
    /// performs inside its own lock. That makes this the only seam a test has
    /// into an erase already in progress, and the work here must not call back
    /// into the recorder: the lock is not recursive, so this thread would
    /// deadlock rather than race. Release another thread instead.
    var duringClear: (@Sendable () -> Void)? {
        get { lock.withLock { clearWork } }
        set { lock.withLock { clearWork = newValue } }
    }

    var record: RetentionRecord? {
        lock.withLock { stored }
    }

    var saved: [RetentionRecord] {
        lock.withLock { saveCalls }
    }

    var clearCallCount: Int {
        lock.withLock { clearCalls }
    }

    var loadCallCount: Int {
        lock.withLock { loadCalls }
    }

    func load() -> RetentionRecord? {
        lock.withLock {
            loadCalls += 1
            return stored
        }
    }

    func save(_ record: RetentionRecord) {
        lock.withLock {
            stored = record
            saveCalls.append(record)
        }
    }

    func clear() {
        let pending: (@Sendable () -> Void)? = lock.withLock {
            stored = nil
            clearCalls += 1
            let next = clearWork
            clearWork = nil
            return next
        }
        pending?()
    }

    // MARK: Private

    private let lock = NSLock()
    private var stored: RetentionRecord?
    private var saveCalls: [RetentionRecord] = []
    private var clearCalls = 0
    private var loadCalls = 0
    private var clearWork: (@Sendable () -> Void)?
}

/// Queue storage whose `purge()` deliberately does nothing while `load()` keeps
/// returning what was persisted.
///
/// This is the failure the real file store swallows: `removeItem` throws, the
/// error is logged, and the bytes stay on disk. The recorder cannot detect it,
/// so the only defence is refusing to re-read the file after a purge it asked
/// for. Nothing else in the suite can reach that path, because the real store
/// actually deletes.
final class PurgeResistantQueueStorage: SignalQueueStorage, @unchecked Sendable {
    // MARK: Internal

    var purgeCallCount: Int {
        lock.withLock { purgeCalls }
    }

    /// What a failed delete left behind. A test asserts on this to show the
    /// signals really did survive, so a passing run cannot be the double
    /// quietly discarding them.
    var survivingSignals: [Signal] {
        lock.withLock { stored }
    }

    func load() -> [Signal] {
        lock.withLock { stored }
    }

    func persist(_ signals: [Signal]) {
        lock.withLock { stored = signals }
    }

    func purge() {
        // The delete failed. Only the count moves.
        lock.withLock { purgeCalls += 1 }
    }

    // MARK: Private

    private let lock = NSLock()
    private var stored: [Signal] = []
    private var purgeCalls = 0
}

/// A clock the test sets rather than one that advances per read.
///
/// The session arithmetic turns on which instant each call saw, and a stepping
/// clock ties that to how many reads happened before it — a count the recorder
/// is free to change.
final class SettableClock: @unchecked Sendable {
    // MARK: Lifecycle

    init(_ start: Date) {
        current = start
    }

    // MARK: Internal

    /// The closure the recorder's `now:` parameter takes.
    var read: @Sendable () -> Date {
        { self.lock.withLock { self.current } }
    }

    func set(_ date: Date) {
        lock.withLock { current = date }
    }

    // MARK: Private

    private let lock = NSLock()
    private var current: Date
}

/// Holds its first send open until the test releases it, deaf to cancellation;
/// every later send answers at once.
///
/// Deafness is the point. A cancelled send that unwinds instantly never shows
/// the window a real one does — `URLSession` has to notice the cancel and the
/// verdict still has to come back — and a hold that resumed on cancel would
/// turn a test of that window into a race it could pass by losing.
///
/// Suspends rather than blocks, so a held drain costs the pool no thread.
final class HeldFirstSendTransport: SignalTransport, @unchecked Sendable {
    // MARK: Internal

    /// Opened once the first send is holding.
    let firstSendHeld = Gate()

    var sentSignalNames: [String] {
        lock.withLock { received.flatMap { $0.signals.map(\.name) } }
    }

    var sendCount: Int {
        lock.withLock { received.count }
    }

    /// Idempotent, and safe before the send arrives: a send that finds the
    /// hold already released does not wait.
    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let next = held
            held = nil
            return next
        }
        waiting?.resume()
    }

    func send(_ batch: SignalBatch) async -> TransportOutcome {
        let isFirst: Bool = lock.withLock {
            received.append(batch)
            return received.count == 1
        }
        guard isFirst else { return .delivered }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                guard !released else { return true }
                held = continuation
                return false
            }
            firstSendHeld.open()
            if resumeNow { continuation.resume() }
        }
        return .delivered
    }

    // MARK: Private

    private let lock = NSLock()
    private var received: [SignalBatch] = []
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
}

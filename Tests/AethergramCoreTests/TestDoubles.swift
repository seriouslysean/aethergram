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
/// when, so the work runs on the drain's own task instead: the erase lands
/// after the claim and before the verdict, every run.
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
        pending?()
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
final class GatedQueueStorage: SignalQueueStorage, @unchecked Sendable {
    // MARK: Internal

    /// Signalled as `purge()` is entered, before it is held or takes effect.
    let purgeEntered = DispatchSemaphore(value: 0)

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
        purgeEntered.signal()
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
final class GatedRetentionStore: RetentionStore, @unchecked Sendable {
    // MARK: Internal

    /// Signalled as `save` is entered, before it is held.
    let saveEntered = DispatchSemaphore(value: 0)
    /// Signalled once `clear` has taken effect.
    let cleared = DispatchSemaphore(value: 0)

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
        saveEntered.signal()
        release.wait()
        lock.withLock {
            stored = record
            saveCalls += 1
        }
    }

    func clear() {
        lock.withLock { stored = nil }
        cleared.signal()
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
        lock.withLock {
            stored = nil
            clearCalls += 1
        }
    }

    // MARK: Private

    private let lock = NSLock()
    private var stored: RetentionRecord?
    private var saveCalls: [RetentionRecord] = []
    private var clearCalls = 0
    private var loadCalls = 0
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

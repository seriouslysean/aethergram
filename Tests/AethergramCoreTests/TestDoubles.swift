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

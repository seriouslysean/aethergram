@testable import AethergramCore
import Foundation

/// The real `FileSignalQueueStorage` behind a call counter.
///
/// A pure spy could only prove the recorder did not *ask* to persist; the real
/// store behind it proves no bytes reached disk either. The consent invariant
/// needs both, so the double delegates instead of faking.
final class RecordingQueueStorage: SignalQueueStorage, @unchecked Sendable {
    // MARK: Lifecycle

    init(directory: URL) {
        self.directory = directory
        backing = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
    }

    // MARK: Internal

    let directory: URL

    /// Drains the recorder's serial writer before any observation.
    ///
    /// Queue writes are submitted under the recorder's lock and performed off
    /// the caller, so reading the file straight after `record()` races the
    /// writer instead of observing it. The fixture wires this to the writer's
    /// barrier, which makes every assertion below see a settled state without
    /// each test having to remember — the same thing the consumer's
    /// deactivation flush does, for the same reason.
    var settle: (@Sendable () -> Void)?

    var fileURL: URL {
        directory.appendingPathComponent("aethergram-signal-queue.json")
    }

    var fileExists: Bool {
        settle?()
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    var fileByteCount: Int {
        settle?()
        return (try? Data(contentsOf: fileURL).count) ?? 0
    }

    /// Reads the queue back through a fresh store, so the assertion sees disk
    /// rather than anything the recorder still holds in memory.
    var signalsOnDisk: [Signal] {
        settle?()
        return FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem).load()
    }

    var persistCallCount: Int {
        settle?()
        return lock.withLock { persistCalls }
    }

    var purgeCallCount: Int {
        settle?()
        return lock.withLock { purgeCalls }
    }

    var loadCallCount: Int {
        lock.withLock { loadCalls }
    }

    func load() -> [Signal] {
        lock.withLock { loadCalls += 1 }
        return backing.load()
    }

    func persist(_ signals: [Signal]) {
        lock.withLock { persistCalls += 1 }
        backing.persist(signals)
    }

    func purge() {
        lock.withLock { purgeCalls += 1 }
        backing.purge()
    }

    // MARK: Private

    private let backing: FileSignalQueueStorage
    private let lock = NSLock()
    private var persistCalls = 0
    private var purgeCalls = 0
    private var loadCalls = 0
}

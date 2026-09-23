@testable import AethergramCore
import AethergramTestSupport
import Foundation
import Testing

/// The writer coalesces, and coalescing is only sound for intents a newer one
/// makes redundant. A snapshot is the whole queue, so a newer snapshot makes an
/// older one redundant; it does not make an erase redundant, because the
/// snapshot says nothing about what else is on disk.
///
/// These drive the writer against a store that only logs what reached it, so
/// what they prove holds for every conformance rather than for the file store.
@Suite("Queue writer ordering", .serialized, .timeLimit(.minutes(1)), .tags(.persistence, .consent))
struct QueueWriterTests {
    /// A reset racing a record: the purge is submitted while an older write is
    /// in flight, and the racer's snapshot lands before the writer comes back
    /// for it. Replacing the purge with the snapshot leaves whatever the store
    /// holds outside the snapshot on disk — a queue it could not read, a file
    /// it could not reach — to be restored under the next grant.
    @Test("A snapshot submitted after an erase cannot stand in for the erase")
    func snapshotAfterAPurgeStillRunsThePurge() async throws {
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let storage = OperationLogStorage()
        let writer = QueueWriter(storage: storage, label: "queue-writer-tests")

        storage.holdNextPersist()
        writer.persist([Signal(name: "pre", sessionID: "session-a", recordedAt: signalDate)])
        await storage.persistEntered.wait()
        writer.purge()
        writer.persist([Signal(name: "post", sessionID: "session-b", recordedAt: signalDate)])
        storage.releasePersist()
        writer.waitForPendingWrites()

        #expect(storage.operations == ["persist pre", "purge", "persist post"])
    }

    /// The other direction stays as it was: an erase after a snapshot makes
    /// the snapshot redundant, and writing it first would put back, however
    /// briefly, what the erase was asked to remove.
    @Test("An erase submitted after a snapshot drops the snapshot")
    func purgeAfterASnapshotDropsTheSnapshot() async throws {
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let storage = OperationLogStorage()
        let writer = QueueWriter(storage: storage, label: "queue-writer-tests")

        storage.holdNextPersist()
        writer.persist([Signal(name: "pre", sessionID: "session-a", recordedAt: signalDate)])
        await storage.persistEntered.wait()
        writer.persist([Signal(name: "declined", sessionID: "session-a", recordedAt: signalDate)])
        writer.purge()
        storage.releasePersist()
        writer.waitForPendingWrites()

        #expect(storage.operations == ["persist pre", "purge"])
    }
}

/// A store that logs each operation in the order it arrives, and can hold one
/// persist open so a test can submit behind it.
///
/// The hold blocks the writer's serial queue; the announcement is a gate,
/// because what acts on it is a test body the cooperative pool has to be free
/// to resume.
private final class OperationLogStorage: SignalQueueStorage, @unchecked Sendable {
    // MARK: Internal

    /// Opened as a held `persist` is entered, before it is held.
    let persistEntered = Gate()

    var operations: [String] {
        lock.withLock { log }
    }

    func holdNextPersist() {
        lock.withLock { held = true }
    }

    func releasePersist() {
        release.signal()
    }

    func load() -> [Signal] {
        []
    }

    func persist(_ signals: [Signal]) {
        let hold = lock.withLock {
            log.append("persist " + signals.map(\.name).joined(separator: ","))
            defer { held = false }
            return held
        }
        guard hold else { return }
        persistEntered.open()
        release.wait()
    }

    func purge() {
        lock.withLock { log.append("purge") }
    }

    // MARK: Private

    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var log: [String] = []
    private var held = false
}

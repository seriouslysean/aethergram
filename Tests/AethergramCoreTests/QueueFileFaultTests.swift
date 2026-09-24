@testable import AethergramCore
import AethergramTestSupport
import Foundation
import Testing

/// What the file store recovers when an operation fails, and what it must
/// not write while recovering. Each case fails a real operation on a real
/// directory at a scripted point, then reads the file back through a fresh
/// store, which is what the next process sees.
@Suite("Queue file faults", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.persistence, .consent))
struct QueueFileFaultTests {
    // MARK: Erases that fail

    /// A decline purges before anything was granted, so a purge that creates
    /// the file, its directory, or a mark is a write consent never allowed.
    /// Both shapes: a directory that exists and one that does not.
    @Test(
        "A purge whose remove is refused over no queue file creates nothing",
        arguments: [false, true]
    )
    func refusedRemoveOverNoFileCreatesNothing(directoryMissing: Bool) throws {
        let root = try #require(TestTempDirectory.url)
        let directory = directoryMissing ? root.appendingPathComponent("never-created") : root
        let operations = FaultingFileOperations()
        operations.script(.remove, .refuse(CocoaError(.fileWriteNoPermission)))
        let storage = faultingStore(directory, operations)

        storage.purge()

        #expect(operations.writes == [.remove, .overwrite, .removeMarker])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(queueFilename).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(markerFilename).path))
        if directoryMissing {
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("A decline before any grant, whose remove is refused, leaves the directory as it found it")
    func declineBeforeGrantWithRefusedRemoveWritesNothing() async throws {
        let directory = try #require(TestTempDirectory.url)
        let operations = FaultingFileOperations()
        operations.script(.remove, .refuse(CocoaError(.fileWriteNoPermission)))
        let recorder = SignalRecorder(
            configuration: testConfiguration(),
            transport: SpyTransport(),
            queueStorage: faultingStore(directory, operations),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: fixedClock(at: signalDate)
        )

        recorder.updateConsent(.declined)
        await recorder.writer.awaitPendingWrites()

        #expect(operations.writes == [.remove, .overwrite, .removeMarker])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("A purge that can neither remove nor overwrite the file marks it, and the next load erases it")
    func refusedRemoveAndOverwriteMarksTheErase() throws {
        let directory = try #require(TestTempDirectory.url)
        FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem).persist(signals("a", "b"))
        let operations = FaultingFileOperations()
        operations.script(.remove, .refuse(CocoaError(.fileWriteNoPermission)))
        operations.script(.overwrite, .refuse(CocoaError(.fileWriteNoPermission)))
        let storage = faultingStore(directory, operations)

        storage.purge()

        #expect(operations.writes == [.remove, .overwrite, .writeMarker])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(markerFilename).path))
        #expect(freshLoad(directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(queueFilename).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(markerFilename).path))
    }

    @Test("A purge whose remove is refused empties the file where it stands")
    func refusedRemoveOverwritesInPlace() throws {
        let directory = try #require(TestTempDirectory.url)
        FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem).persist(signals("a", "b"))
        let operations = FaultingFileOperations()
        operations.script(.remove, .refuse(CocoaError(.fileWriteNoPermission)))
        let storage = faultingStore(directory, operations)

        storage.purge()

        #expect(operations.writes == [.remove, .overwrite, .removeMarker])
        #expect(freshLoad(directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(markerFilename).path))
    }

    /// "No such file" is a Foundation code, and 4 means something else in
    /// another domain: an interrupted call, in POSIX's. Read by its code
    /// alone, a refusal there says the queue is gone while it still stands.
    @Test("A remove refused with another domain's error that shares no-such-file's code still erases the queue")
    func refusalOutsideFoundationIsNotReadAsNothingThere() throws {
        let directory = try #require(TestTempDirectory.url)
        FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem).persist(signals("a", "b"))
        let operations = FaultingFileOperations()
        operations.script(.remove, .refuse(NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR))))
        let storage = faultingStore(directory, operations)

        storage.purge()

        #expect(operations.writes == [.remove, .overwrite, .removeMarker])
        #expect(freshLoad(directory).isEmpty)
    }

    // MARK: Files past the limit

    /// Restore trims oldest-first to the limit in force and writes the trim
    /// back; a file within the limit is left as it was written until the next
    /// write.
    @Test("A restored queue file keeps its newest signals up to the limit", arguments: [3, 5])
    func restoreKeepsTheNewestUpToTheLimit(count: Int) async throws {
        let directory = try #require(TestTempDirectory.url)
        let names = (0 ..< count).map { "old.\($0)" }
        try JSONEncoder().encode(names.map { signal($0) }).write(to: directory.appendingPathComponent(queueFilename))
        let operations = FaultingFileOperations()
        let transport = SpyTransport(defaultOutcome: .retryable(reason: "held"))
        let recorder = SignalRecorder(
            configuration: testConfiguration(queueLimit: 3),
            transport: transport,
            queueStorage: faultingStore(directory, operations),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: fixedClock(at: signalDate)
        )

        recorder.updateConsent(.granted)
        await recorder.drain()
        await recorder.writer.awaitPendingWrites()

        let kept = Array(names.suffix(3))
        #expect(transport.batches.first?.signals.map(\.name) == kept)
        #expect(freshLoad(directory).map(\.name) == kept)
        #expect(operations.writes == (count > 3 ? [.createDirectory, .replace] : []))
    }

    /// A late read — a read that failed at load and succeeded at a later
    /// write — keeps the newest `queueLimit` of what the file held ahead of
    /// the snapshot.
    @Test("A late read of a file past the limit carries its newest signals ahead of the snapshot")
    func lateReadCarriesTheNewestUpToTheLimit() throws {
        let directory = try #require(TestTempDirectory.url)
        let names = (0 ..< 5).map { "old.\($0)" }
        try JSONEncoder().encode(names.map { signal($0) }).write(to: directory.appendingPathComponent(queueFilename))
        let operations = FaultingFileOperations()
        let storage = faultingStore(directory, operations)
        storage.adoptQueueLimit(3)
        operations.script(.read, .refuse(CocoaError(.fileReadNoPermission)))

        #expect(storage.load().isEmpty)
        operations.clear()
        storage.persist([signal("new")])
        #expect(operations.writes == [.createDirectory, .replace])

        #expect(freshLoad(directory).map(\.name) == names.suffix(3) + ["new"])
    }
}

private let queueFilename = "aethergram-signal-queue.json"
private let markerFilename = "aethergram-signal-queue.json.erase-required"
private let signalDate = Date(timeIntervalSinceReferenceDate: 790_000_000)

private func faultingStore(_ directory: URL, _ operations: FaultingFileOperations) -> FileSignalQueueStorage {
    FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem, operations: operations)
}

private func freshLoad(_ directory: URL) -> [Signal] {
    FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem).load()
}

private func signal(_ name: String, detail: String = "value") -> Signal {
    Signal(name: name, parameters: ["detail": detail], sessionID: "session-a", recordedAt: signalDate)
}

private func signals(_ names: String...) -> [Signal] {
    names.map { signal($0) }
}

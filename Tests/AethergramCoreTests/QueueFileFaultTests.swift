@testable import AethergramCore
import AethergramTestSupport
import Foundation
import Testing

/// What the file store recovers when a write fails partway, and what it must
/// not write while recovering. Each case fails a real operation on a real
/// directory at a scripted point, then reads the file back through a fresh
/// store, which is what the next process sees.
@Suite("Queue file faults", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.persistence, .consent))
struct QueueFileFaultTests {
    // MARK: Appends that fail partway

    @Test("An append cut off partway is replaced whole by the same write, not continued")
    func partialAppendIsReplacedWhole() throws {
        let directory = try #require(TestTempDirectory.url)
        let operations = FaultingFileOperations()
        let storage = faultingStore(directory, operations)
        storage.persist(signals("a", "b"))

        let line = try encodedLine(signal("c"))
        operations.script(.append, .partial(bytes: line.count / 2, then: CocoaError(.fileWriteOutOfSpace)))
        operations.clear()
        storage.persist(signals("a", "b", "c"))

        #expect(operations.writes == [.append, .createDirectory, .replace])
        #expect(freshLoad(directory).map(\.name) == ["a", "b", "c"])

        // The replacement leaves a file the store knows, so appending resumes.
        operations.clear()
        storage.persist(signals("a", "b", "c", "d"))
        #expect(operations.writes == [.append])
        #expect(freshLoad(directory).map(\.name) == ["a", "b", "c", "d"])
    }

    @Test("An append cut off partway and a replacement that fails leave every whole line for the next process")
    func partialAppendThenFailedReplaceKeepsWholeLines() throws {
        let directory = try #require(TestTempDirectory.url)
        let operations = FaultingFileOperations()
        let storage = faultingStore(directory, operations)
        storage.persist(signals("a", "b"))

        let line = try encodedLine(signal("c"))
        operations.script(.append, .partial(bytes: line.count / 2, then: CocoaError(.fileWriteOutOfSpace)))
        operations.script(.replace, .refuse(CocoaError(.fileWriteOutOfSpace)))
        operations.clear()
        storage.persist(signals("a", "b", "c"))
        #expect(operations.writes == [.append, .createDirectory, .replace])

        // The next process: the fragment is dropped, and its first write
        // replaces the file rather than appending after the fragment.
        let restartOperations = FaultingFileOperations()
        let restarted = faultingStore(directory, restartOperations)
        let restored = restarted.load()
        #expect(restored.map(\.name) == ["a", "b"])
        restartOperations.clear()
        restarted.persist(restored + [signal("d")])
        #expect(restartOperations.writes == [.createDirectory, .replace])
        #expect(freshLoad(directory).map(\.name) == ["a", "b", "d"])
    }

    // MARK: Tails a kill leaves

    /// Expected results come from where the cut falls, not from the store's
    /// decoder: every line whole before it, plus a last line cut exactly at
    /// its newline. The last signal carries a character outside ASCII, so
    /// some cuts fall inside one.
    @Test("A tail cut at any byte of the last two lines keeps every whole line and appends only after a whole line")
    func tailCutAtEveryOffsetKeepsWholeLines() throws {
        let directory = try #require(TestTempDirectory.url)
        let fileURL = directory.appendingPathComponent(queueFilename)
        let written = [signal("a"), signal("b"), signal("c", detail: "caf\u{E9} \u{1F4E6}")]
        let lines = try written.map(encodedLine)
        let whole = lines.reduce(Data(), +)
        // Where each line ends, its newline included.
        let ends = lines.indices.map { lines[...$0].reduce(0) { $0 + $1.count } }

        for cut in ends[0] ... whole.count {
            try whole.prefix(cut).write(to: fileURL)
            let expected = written.indices.filter { cut >= ends[$0] - 1 }.map { written[$0].name }
            let endsOnNewline = ends.contains(cut)

            let operations = FaultingFileOperations()
            let storage = faultingStore(directory, operations)
            let loaded = storage.load()
            #expect(loaded.map(\.name) == expected, "cut at \(cut)")

            operations.clear()
            storage.persist(loaded + [signal("next")])
            let expectedWrites: [FaultingFileOperations.Operation] = endsOnNewline ? [.append] : [.createDirectory, .replace]
            #expect(operations.writes == expectedWrites, "cut at \(cut)")
            #expect(freshLoad(directory).map(\.name) == expected + ["next"], "cut at \(cut)")
        }
    }

    @Test("A last line that decodes without its newline is kept, and the next write replaces rather than runs into it")
    func finalLineWithoutNewlineIsKeptAndReplaced() throws {
        let directory = try #require(TestTempDirectory.url)
        var bytes = try signals("a", "b").map(encodedLine).reduce(Data(), +)
        try bytes.append(encodedLine(signal("c")).dropLast())
        try bytes.write(to: directory.appendingPathComponent(queueFilename))

        let operations = FaultingFileOperations()
        let storage = faultingStore(directory, operations)
        let loaded = storage.load()
        #expect(loaded.map(\.name) == ["a", "b", "c"])

        operations.clear()
        storage.persist(loaded + [signal("d")])
        #expect(operations.writes == [.createDirectory, .replace])
        #expect(freshLoad(directory).map(\.name) == ["a", "b", "c", "d"])
    }

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
    /// back; a file within the limit is left as it was written, array or not,
    /// until the next write.
    @Test("A restored queue file keeps its newest signals up to the limit", arguments: FileShape.allCases)
    func restoreKeepsTheNewestUpToTheLimit(shape: FileShape) async throws {
        let directory = try #require(TestTempDirectory.url)
        let names = (0 ..< shape.count).map { "old.\($0)" }
        try shape.encode(names.map { signal($0) }).write(to: directory.appendingPathComponent(queueFilename))
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
        let bytes = try Data(contentsOf: directory.appendingPathComponent(queueFilename))
        let rewritten = shape.count > 3
        #expect((bytes.first == UInt8(ascii: "[")) == (shape.isArray && !rewritten))
        #expect(operations.writes == (rewritten ? [.createDirectory, .replace] : []))
    }

    /// A late read — a read that failed at load and succeeded at a later
    /// write — keeps the newest `queueLimit` of what the file held ahead of
    /// the snapshot, in lines whatever the file was written as.
    @Test("A late read of a file past the limit carries its newest signals ahead of the snapshot", arguments: FileShape.allCases)
    func lateReadCarriesTheNewestUpToTheLimit(shape: FileShape) throws {
        let directory = try #require(TestTempDirectory.url)
        let names = (0 ..< shape.count).map { "old.\($0)" }
        try shape.encode(names.map { signal($0) }).write(to: directory.appendingPathComponent(queueFilename))
        let operations = FaultingFileOperations()
        let storage = faultingStore(directory, operations)
        storage.adoptQueueLimit(3)
        operations.script(.read, .refuse(CocoaError(.fileReadNoPermission)))

        #expect(storage.load().isEmpty)
        operations.clear()
        storage.persist([signal("new")])
        #expect(operations.writes == [.createDirectory, .replace])

        #expect(freshLoad(directory).map(\.name) == names.suffix(3) + ["new"])
        let bytes = try Data(contentsOf: directory.appendingPathComponent(queueFilename))
        #expect(bytes.first == UInt8(ascii: "{"))
    }
}

/// How a queue file on disk was written: by 0.3.x as one array, or as lines.
enum FileShape: CaseIterable, CustomTestStringConvertible, Sendable {
    case arrayWithinLimit
    case arrayPastLimit
    case linesPastLimit

    var count: Int {
        self == .arrayWithinLimit ? 3 : 5
    }

    var isArray: Bool {
        self != .linesPastLimit
    }

    var testDescription: String {
        switch self {
        case .arrayWithinLimit: "an array file within the limit"
        case .arrayPastLimit: "an array file past the limit"
        case .linesPastLimit: "a line file past the limit"
        }
    }

    func encode(_ signals: [Signal]) throws -> Data {
        isArray ? try JSONEncoder().encode(signals) : try signals.map(encodedLine).reduce(Data(), +)
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

/// Encoded here rather than by the store, so a test that reads it back is not
/// checking the store against itself.
private func encodedLine(_ signal: Signal) throws -> Data {
    var line = try JSONEncoder().encode(signal)
    line.append(0x0A)
    return line
}

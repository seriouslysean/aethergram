@testable import AethergramCore
import AethergramTestSupport
import Foundation
import Testing

/// A record adds one signal to the queue, and the file store rewrote the whole
/// queue for it: a queue filled offline to its limit cost the square of its
/// size in bytes written. What the store writes has to track what changed,
/// and what it reads has to survive both the kill that interrupts an append
/// and a file an earlier release wrote.
@Suite("Queue file format", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.persistence))
struct QueueFileFormatTests {
    @Test("Filling the queue one record at a time writes bytes in proportion to the queue, not its square")
    func fillingTheQueueWritesLinearBytes() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        let probe = WriteProbe(fileURL: directory.appendingPathComponent("aethergram-signal-queue.json"))

        var queue: [Signal] = []
        for index in 0 ..< AethergramConfiguration.defaultQueueLimit {
            queue.append(Signal(
                name: "filled.\(index)",
                parameters: ["detail": String(repeating: "x", count: 64)],
                sessionID: "session-a",
                recordedAt: signalDate
            ))
            storage.persist(queue)
            try probe.observe()
        }

        // Known-bad shape kept as the assertion: rewriting on every record
        // writes about half the queue's count times the final file.
        #expect(probe.bytesWritten <= 2 * probe.fileSize)
        #expect(FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem).load() == queue)
    }

    @Test("A write cut off partway through its last line loses that line and nothing before it")
    func tornLastLineLoadsTheRest() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let kept = [
            Signal(name: "kept.a", sessionID: "session-a", recordedAt: signalDate),
            Signal(name: "kept.b", sessionID: "session-a", recordedAt: signalDate)
        ]
        let torn = try encodedLine(Signal(name: "torn.c", sessionID: "session-a", recordedAt: signalDate))
        var bytes = try kept.map(encodedLine).reduce(Data(), +)
        bytes.append(torn.prefix(torn.count / 2))
        try bytes.write(to: fileURL)

        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        let loaded = storage.load()
        #expect(loaded.map(\.name) == ["kept.a", "kept.b"])

        // The fragment is still in the file, so the next write cannot go on
        // after it: a line glued to a fragment is a corrupt line mid-file,
        // and that costs the whole queue.
        storage.persist(loaded + [Signal(name: "next.d", sessionID: "session-b", recordedAt: signalDate)])
        let reborn = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(reborn.load().map(\.name) == ["kept.a", "kept.b", "next.d"])
    }

    @Test("A queue file written as one array by an earlier release still loads, and the next write keeps it")
    func arrayFileFromAnEarlierReleaseLoads() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let earlier = [
            Signal(name: "earlier.a", parameters: ["k": "v"], sessionID: "session-a", recordedAt: signalDate),
            Signal(name: "earlier.b", floatValue: 2.5, sessionID: "session-a", recordedAt: signalDate)
        ]
        try JSONEncoder().encode(earlier).write(to: fileURL)

        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        let loaded = storage.load()
        #expect(loaded == earlier)

        // An append after an array's closing bracket is a file nothing can
        // read, and a file nothing can read is purged.
        storage.persist(loaded + [Signal(name: "next.c", sessionID: "session-b", recordedAt: signalDate)])
        let reborn = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(reborn.load().map(\.name) == ["earlier.a", "earlier.b", "next.c"])
    }

    @Test("A delivery that takes signals off the front leaves the rest in order for the next process")
    func rewriteAfterDeliveryKeepsOrder() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let signals = (0 ..< 5).map { Signal(name: "queued.\($0)", sessionID: "session-a", recordedAt: signalDate) }
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)

        storage.persist(Array(signals[0 ..< 3]))
        storage.persist(Array(signals[1 ..< 4]))
        storage.persist(Array(signals[1 ..< 5]))

        let reborn = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(reborn.load().map(\.name) == ["queued.1", "queued.2", "queued.3", "queued.4"])
    }

    /// Only a cut-off last line is a kill's signature. A line that fails
    /// ahead of others was written whole and still does not decode, which is
    /// a file that will not decode later either.
    @Test("A line that does not decode ahead of the last loads as empty and is purged")
    func corruptLineAheadOfTheLastPurges() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        var bytes = try encodedLine(Signal(name: "whole.a", sessionID: "session-a", recordedAt: signalDate))
        bytes.append(Data("{\"not\":\"a signal\"}\n".utf8))
        try bytes.append(encodedLine(Signal(name: "whole.b", sessionID: "session-a", recordedAt: signalDate)))
        try bytes.write(to: fileURL)

        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(storage.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}

/// One signal as a line of the queue file, encoded here rather than by the
/// store, so a test that reads it back is not checking the store against
/// itself.
private func encodedLine(_ signal: Signal) throws -> Data {
    var line = try JSONEncoder().encode(signal)
    line.append(0x0A)
    return line
}

/// Counts what reaching each state of the queue file cost in bytes: the whole
/// file when it was replaced, which a changed file number shows, and the
/// growth when it was extended in place.
private final class WriteProbe {
    // MARK: Lifecycle

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Internal

    private(set) var bytesWritten = 0
    private(set) var fileSize = 0

    func observe() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let number = try #require(attributes[.systemFileNumber] as? Int)
        let size = try #require(attributes[.size] as? Int)
        bytesWritten += number == fileNumber ? size - fileSize : size
        fileNumber = number
        fileSize = size
    }

    // MARK: Private

    private let fileURL: URL
    private var fileNumber: Int?
}

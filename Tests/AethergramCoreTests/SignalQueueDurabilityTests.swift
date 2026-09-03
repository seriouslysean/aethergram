@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// The queue is durable because the OS kills a suspended extension without
/// warning, and a signal that only exists in memory at that moment is a signal
/// that never happened.
@Suite("Signal queue durability", .tempDirectory, .serialized, .tags(.persistence))
struct SignalQueueDurabilityTests {
    /// Simulates the kill: the first recorder records and is then discarded
    /// without ever draining, and a second recorder is built over the same
    /// directory. The dead process's signals must arrive, and must precede
    /// anything the new process recorded.
    @Test("Signals survive a discarded recorder and keep their place in line")
    func queuedSignalsSurviveProcessDeathAndLeadTheNewOnes() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let deadTransport = SpyTransport()
        let dead = makeFixture(
            directory: directory,
            transport: deadTransport,
            now: steppingClock(from: start)
        )
        dead.recorder.updateConsent(.granted)
        dead.recorder.record("old.a")
        dead.recorder.record("old.b")
        // The write is serialized off the caller, so waiting for it is
        // what the consumer's own deactivation flush does; reading the file
        // without it races the writer instead of observing it.
        dead.recorder.writer.waitForPendingWrites()
        #expect(dead.storage.signalsOnDisk.count == 2)

        let revivedStart = try testDate(year: 2026, month: 1, day: 6)
        let revived = makeFixture(directory: directory, now: steppingClock(from: revivedStart))
        revived.recorder.updateConsent(.granted)
        revived.recorder.record("new.c")
        await revived.recorder.drain()
        revived.recorder.writer.waitForPendingWrites()

        #expect(deadTransport.sendCount == 0)
        #expect(revived.transport.sentSignalNames == ["old.a", "old.b", "new.c"])
        #expect(!revived.storage.fileExists)
    }

    /// A batch the endpoint could not take stays queued and stays on disk, so
    /// the next process picks it up.
    @Test("A retryable outcome leaves the batch queued and on disk")
    func retryableOutcomeKeepsTheBatchQueued() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let transport = SpyTransport(defaultOutcome: .retryable(reason: "offline"))
        let fixture = makeFixture(directory: directory, transport: transport, now: steppingClock(from: start))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        fixture.recorder.record("beta")
        await fixture.recorder.drain()

        // One attempt, then the loop stops rather than spinning on a
        // transport that just refused.
        #expect(transport.sendCount == 1)
        #expect(fixture.storage.fileExists)
        #expect(fixture.storage.signalsOnDisk.map(\.name) == ["alpha", "beta"])
    }

    /// Delivered and permanently rejected batches both leave the queue: a batch
    /// the server will keep refusing is not worth a retry slot forever.
    ///
    /// One signal and a long coalescing interval, because delivery now
    /// schedules itself: the task the record schedules is still asleep, so the
    /// drain this test drives is the only one that runs and the outcome cannot
    /// depend on how the two interleave. Batch slicing across several signals
    /// is pinned by `queuedSignalsSurviveProcessDeathAndLeadTheNewOnes`.
    @Test(
        "A delivered or permanently rejected batch leaves the queue and the file",
        arguments: [TransportOutcome.delivered, .permanent(reason: "rejected")]
    )
    func terminalOutcomesRemoveTheBatchFromDisk(outcome: TransportOutcome) async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let transport = SpyTransport(outcomes: [outcome], defaultOutcome: .retryable(reason: "stop"))
        let fixture = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            transport: transport,
            now: steppingClock(from: start)
        )

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        #expect(fixture.storage.fileExists)

        await fixture.recorder.drain()

        #expect(transport.sentSignalNames == ["alpha"])
        #expect(fixture.storage.signalsOnDisk.isEmpty)
        #expect(!fixture.storage.fileExists)
    }

    /// Coalescing must not cost a signal.
    ///
    /// Writes are serialized off the caller and only the newest snapshot is
    /// written, so a burst of records produces far fewer writes than records.
    /// That is sound only because a snapshot is the whole queue rather than a
    /// delta — this is the test that says so. A kill is simulated the way the
    /// others do it, by abandoning the recorder and reading the directory back
    /// through a fresh store: whatever is there is what would have survived.
    @Test("Every signal in a rapid burst reaches disk once the writer drains")
    func rapidBurstLosesNothingToCoalescing() throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        // Long interval and a batch larger than the burst, so no delivery
        // competes with the writer and the file is the only thing moving.
        let fixture = makeFixture(
            directory: directory,
            configuration: testConfiguration(batchSize: 500, transmitInterval: 3600),
            transport: SpyTransport(defaultOutcome: .retryable(reason: "offline")),
            now: steppingClock(from: start)
        )

        fixture.recorder.updateConsent(.granted)
        let names = (0 ..< 50).map { "burst.\($0)" }
        for name in names {
            fixture.recorder.record(name)
        }

        // The double settles the writer before it reads, so this is the
        // post-drain state a next process would inherit.
        #expect(fixture.storage.signalsOnDisk.map(\.name) == names)
        // Coalescing did its job: far fewer writes than records. Asserted
        // as a bound rather than a number, because how many collapse
        // depends on scheduling and only the loss would be a defect.
        #expect(fixture.storage.persistCallCount <= names.count)
    }

    /// Past the cap the oldest signals go, because the recent ones describe the
    /// version someone is actually running.
    @Test("Queue overflow drops the oldest signals and keeps the newest")
    func queueOverflowDropsOldestSignals() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(
            directory: directory,
            configuration: testConfiguration(queueLimit: 3),
            now: steppingClock(from: start)
        )

        fixture.recorder.updateConsent(.granted)
        for index in 0 ..< 5 {
            fixture.recorder.record("signal.\(index)")
        }

        #expect(fixture.storage.signalsOnDisk.map(\.name) == ["signal.2", "signal.3", "signal.4"])
        await fixture.recorder.drain()
        #expect(fixture.transport.sentSignalNames == ["signal.2", "signal.3", "signal.4"])
    }

    /// A queue that cannot be decoded is a queue that cannot be sent. Dropping
    /// it beats retrying a corrupt file on every launch forever, and the drop
    /// has to be a delete rather than a silent empty read.
    @Test("A corrupt queue file loads as empty and is purged")
    func corruptQueueFileLoadsEmptyAndPurges() throws {
        let directory = try #require(TestTempDirectory.url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        try Data("this is not json".utf8).write(to: fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)

        #expect(storage.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// The recorder recovers from the same corruption rather than wedging: a
    /// grant after a corrupt file still records and still delivers.
    @Test("A recorder over a corrupt queue file still records and delivers")
    func recorderRecoversFromCorruptQueueFile() async throws {
        let directory = try #require(TestTempDirectory.url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: fileURL)

        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))
        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        await fixture.recorder.drain()

        #expect(fixture.transport.sentSignalNames == ["alpha"])
    }
}

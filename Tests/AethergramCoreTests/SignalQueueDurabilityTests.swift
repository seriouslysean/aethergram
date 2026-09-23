@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// The queue is durable because the OS kills a suspended extension without
/// warning, and a signal that only exists in memory at that moment is a signal
/// that never happened.
///
/// The time limit covers the mid-send arms, which drive a drain against work
/// running on another thread: a wait that never returns has to fail under its
/// own name rather than stall the run until a runner is cancelled.
@Suite("Signal queue durability", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.persistence))
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

    /// The other half of surviving a kill: a signal that outlives the process
    /// that recorded it also outlives the session it ran in, and the process
    /// that finally sends it has opened one of its own. Attribution belongs to
    /// the record, so the restored signal keeps the session it happened in
    /// while the new one takes the session now open — in the same batch, which
    /// a session read once per send cannot express.
    @Test("A restored signal carries the session it was recorded in, not the one that sent it")
    func restoredSignalsKeepTheSessionTheyWereRecordedIn() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let dead = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            now: steppingClock(from: start)
        )
        dead.recorder.updateConsent(.granted)
        dead.recorder.beginSession()
        dead.recorder.record("old")
        dead.recorder.writer.waitForPendingWrites()
        #expect(dead.transport.sendCount == 0)

        let revived = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            now: steppingClock(from: start.addingTimeInterval(3600))
        )
        revived.recorder.updateConsent(.granted)
        revived.recorder.beginSession()
        revived.recorder.record("new")
        await revived.recorder.drain()

        // One batch, so a session stamped at send time would hand both signals
        // the identifier the second process opened.
        #expect(revived.transport.sendCount == 1)
        let sent = revived.transport.sentSignals
        #expect(sent.map(\.name) == ["old", "new"])
        let restored = try #require(sent.first)
        let fresh = try #require(sent.last)
        #expect(!restored.sessionID.isEmpty)
        #expect(restored.sessionID != fresh.sessionID)
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

    /// A record landing mid-send can evict the front of a full queue, so the
    /// queue no longer starts with the batch in flight. Part of that batch is
    /// still there and part of it is gone, and no comparison of the signals
    /// themselves can say which: the clock is the host's and need not advance,
    /// so two signals recorded alike are equal. Only a count of what was
    /// evicted since the claim tells them apart.
    ///
    /// Every signal here is deliberately equal to every other, and three sends
    /// is the only correct total: two says the mid-send record was dropped
    /// unsent, four says a delivered one was sent again. The eviction lands
    /// inside the send because `duringFirstSend` runs while the send is held
    /// open, which puts it after the claim and before the verdict on every run.
    @Test(
        "A batch whose front was evicted during the send removes only what it sent",
        arguments: [TransportOutcome.delivered, .permanent(reason: "rejected")]
    )
    func evictionDuringSendRemovesOnlyWhatItSent(outcome: TransportOutcome) async throws {
        let directory = try #require(TestTempDirectory.url)
        let noon = try testDate(year: 2026, month: 1, day: 5)
        let storage = RecordingQueueStorage(directory: directory)
        let transport = MidSendTransport(outcome: outcome)
        let recorder = SignalRecorder(
            configuration: testConfiguration(queueLimit: 2, transmitInterval: 3600),
            transport: transport,
            queueStorage: storage,
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { ["env.key": "env-value"] },
            calendar: testCalendar,
            now: fixedClock(at: noon)
        )
        storage.settle = { [weak recorder] in recorder?.writer.waitForPendingWrites() }

        recorder.updateConsent(.granted)
        recorder.record("x")
        recorder.record("x")
        // Takes the queue one past its cap while the batch above is in flight,
        // so the eviction drops a signal that batch already carried.
        transport.duringFirstSend = { recorder.record("x") }
        await recorder.drain()

        let sent = transport.sentSignals
        #expect(sent.count == 3)
        // Known-bad input kept as the assertion: nothing in these signals tells
        // them apart, which is what a removal keyed on value gets wrong.
        #expect(sent.allSatisfy { $0 == sent.first })
        #expect(storage.signalsOnDisk.isEmpty)
    }

    /// `JSONEncoder` throws on a non-finite `Double`, and it encodes the queue
    /// as one array: a single such signal stops every signal from persisting
    /// and takes the batch down with it at the transport.
    @Test(
        "A non-finite measure costs its own value and nothing else",
        arguments: [Double.nan, Double.infinity]
    )
    func nonFiniteMeasureDoesNotStopTheQueueFromPersisting(measure: Double) throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            transport: SpyTransport(defaultOutcome: .retryable(reason: "offline")),
            now: steppingClock(from: start)
        )

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("before", floatValue: 1)
        fixture.recorder.record("during", floatValue: measure)
        fixture.recorder.record("after", floatValue: 2)

        let onDisk = fixture.storage.signalsOnDisk
        #expect(onDisk.map(\.name) == ["before", "during", "after"])
        #expect(onDisk.map(\.floatValue) == [1, nil, 2])
    }

    /// The coercion is the type's invariant rather than one initializer's, so
    /// it has to hold for a value read back as well as for one recorded. The
    /// package's own encoder cannot write a non-finite measure, but the
    /// decoder belongs to `Signal` and a host's `SignalQueueStorage` chooses
    /// its own coder: a decoded NaN would reach the encoder that refuses it and
    /// cost the whole file, which is the failure `record` is already spared.
    @Test(
        "A non-finite measure decoded off disk loads as no measure",
        arguments: ["nan", "inf"]
    )
    func nonFiniteMeasureDecodedOffDiskLoadsAsNoMeasure(measure: String) throws {
        let recordedAt = try testDate(year: 2026, month: 1, day: 5).timeIntervalSinceReferenceDate
        let json = """
        [{"name":"old.a","parameters":{},"floatValue":"\(measure)",\
        "sessionID":"session-a","recordedAt":\(recordedAt)}]
        """
        // The one strategy that can carry a non-finite value through JSON at
        // all; the default refuses to write it and has nothing to read.
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )

        let signals = try decoder.decode([Signal].self, from: Data(json.utf8))

        let signal = try #require(signals.first)
        #expect(signal.name == "old.a")
        #expect(signal.floatValue == nil)
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

    /// A queue file written before signals carried a session cannot be
    /// attributed to one, and defaulting the key would file its signals under a
    /// session they never ran in. Required is what makes the file unreadable
    /// instead, which is the upgrade path: purge and keep recording.
    @Test("A queue file with no session identifier loads as empty and is purged")
    func queueFileWithoutSessionIdentifierLoadsEmptyAndPurges() throws {
        let directory = try #require(TestTempDirectory.url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        // Written by hand rather than encoded, because the shape under test is
        // one this package can no longer produce. `JSONDecoder`'s default date
        // strategy reads seconds since the reference date.
        let recordedAt = try testDate(year: 2026, month: 1, day: 5).timeIntervalSinceReferenceDate
        let fields = #""name":"old.a","parameters":{"env.key":"env-value"},"recordedAt":\#(recordedAt)"#
        try Data("[{\(fields)}]".utf8).write(to: fileURL)

        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)

        #expect(storage.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        // The control: the same object with the session key present decodes.
        // Without it the purge above would pass for any reason at all — a date
        // in the wrong form, a key spelled differently — rather than for the
        // one this test is about.
        try Data("[{\(fields),\"sessionID\":\"session-a\"}]".utf8).write(to: fileURL)

        #expect(storage.load().map(\.sessionID) == ["session-a"])
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

    /// `removeItem` can fail while the file it targets is still writable — a
    /// directory that refuses deletion but not writes to what it already
    /// holds. `purge()` must still leave nothing to restore: a fresh store
    /// over the same file, opened later under a new grant, must not find
    /// signals recorded before the purge that was supposed to erase them.
    @Test(
        "A purge that cannot remove the file still reads back empty under a later grant",
        .enabled(if: getuid() != 0, "root bypasses the permission that makes removal fail")
    )
    func purgeOverwritesWhenRemovalFailsSoDeclinedSignalsNeverReturn() throws {
        let directory = try #require(TestTempDirectory.url)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "declined.a", sessionID: "declined-session", recordedAt: signalDate)])
        #expect(!storage.load().isEmpty)

        let originalPermissions = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int ?? 0o755
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        // The temp-directory trait removes this tree on teardown, which needs
        // write access back on the directory itself.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: directory.path
            )
        }

        storage.purge()

        // Removal was refused, so the file is still there — proves the
        // overwrite fallback ran rather than a deletion nobody blocked.
        #expect(try Data(contentsOf: fileURL) == Data("[]".utf8))
        let revived = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(revived.load().isEmpty)
    }

    /// A read that failed is not a queue that is wrong, and the two arrive at
    /// the same `catch`. A file that cannot be decoded will never decode, so
    /// dropping it is the only way forward; a file that cannot be read *now* —
    /// a protected file while the device is locked, a container the process
    /// cannot reach for a moment — is a queue that is still good, and purging
    /// it destroys signals nothing was ever wrong with.
    ///
    /// The write that follows is the other half. The queue this instance
    /// handed back does not hold what it could not read, so persisting it over
    /// the file would finish what the purge was stopped from doing.
    @Test(
        "A queue file that cannot be read survives the load and the write after it",
        .enabled(if: getuid() != 0, "root reads a file whose permissions refuse everyone")
    )
    func unreadableQueueFileIsPreservedRatherThanPurged() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "pending.a", sessionID: "session-a", recordedAt: signalDate)])
        #expect(!storage.load().isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }

        #expect(storage.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        storage.persist([Signal(name: "later.b", sessionID: "session-b", recordedAt: signalDate)])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let readable = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(readable.load().map(\.name) == ["pending.a"])
    }

    /// The recorder reads the queue once per grant, so a read that fails is
    /// never asked again by the process that made it. Holding the writes off
    /// the file until then holds them off for the rest of the process: every
    /// signal it records has nothing on disk to survive a kill, long after the
    /// file became readable again.
    ///
    /// The write is what finds out. Once the file reads, what it held goes
    /// ahead of the snapshot, because the recorder never saw it and the next
    /// process is the only one that can send it.
    @Test(
        "A queue file that becomes readable again takes the writes, and keeps what it held",
        .enabled(if: getuid() != 0, "root reads a file whose permissions refuse everyone")
    )
    func queueFileReadableAgainTakesTheWritesAndKeepsWhatItHeld() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "pending.a", sessionID: "session-a", recordedAt: signalDate)])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }
        #expect(storage.load().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        storage.persist([Signal(name: "later.b", sessionID: "session-b", recordedAt: signalDate)])

        let next = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(next.load().map(\.name) == ["pending.a", "later.b"])
    }

    /// What a late read rescued belongs to no snapshot, so a snapshot cannot
    /// empty it: the recorder's "everything delivered" is about what it holds,
    /// and it never held these. Only an erase reaches them.
    @Test(
        "An empty snapshot keeps what a late read rescued, and an erase does not",
        .enabled(if: getuid() != 0, "root reads a file whose permissions refuse everyone")
    )
    func emptySnapshotKeepsWhatALateReadRescued() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "pending.a", sessionID: "session-a", recordedAt: signalDate)])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }
        #expect(storage.load().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        storage.persist([Signal(name: "later.b", sessionID: "session-b", recordedAt: signalDate)])
        storage.persist([])
        let afterDelivery = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(afterDelivery.load().map(\.name) == ["pending.a"])

        storage.purge()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        storage.persist([Signal(name: "granted.c", sessionID: "session-c", recordedAt: signalDate)])
        let afterErase = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(afterErase.load().map(\.name) == ["granted.c"])
    }

    /// The one purge failure the overwrite fallback cannot reach: a file the
    /// filesystem refuses to delete *and* to write over. The bytes stay, and
    /// the recorder's refusal to re-read them lasts exactly as long as its own
    /// process — so the next one, under a later grant, restores signals a
    /// decline was supposed to have ended. SECURITY.md names that outcome in
    /// scope, so what the store cannot delete it has to leave marked.
    @Test(
        "A purge that can neither delete nor overwrite still restores nothing later",
        .enabled(if: getuid() != 0, "root writes a file the immutable flag refuses")
    )
    func purgeThatCannotTouchTheFileStillRestoresNothing() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "declined.a", sessionID: "declined-session", recordedAt: signalDate)])

        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fileURL.path)
        }

        storage.purge()

        // The fixture has to be the failure it claims. Both halves were
        // refused, so the declined signals are still in the file — otherwise
        // this passes for the ordinary reason and proves nothing.
        #expect(try JSONDecoder().decode([Signal].self, from: Data(contentsOf: fileURL)).count == 1)

        // A fresh store is the next process, opened under a later grant.
        let reborn = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(reborn.load().isEmpty)
    }

    /// The mark is a debt, not a tombstone: it has to come off the moment the
    /// delete it stands in for lands, or the first unremovable file a store
    /// ever meets would end restoration for that directory forever.
    @Test(
        "A mark left by a failed purge is settled by the delete that follows",
        .enabled(if: getuid() != 0, "root writes a file the immutable flag refuses")
    )
    func markLeftByAFailedPurgeIsSettledByTheNextDelete() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "declined.a", sessionID: "declined-session", recordedAt: signalDate)])
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fileURL.path)
        storage.purge()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fileURL.path)

        let reborn = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(reborn.load().isEmpty)
        // Nothing at all left behind, named without naming a file the store
        // does not promise: the declined queue and the mark both went.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        // And the directory is usable again rather than poisoned.
        reborn.persist([Signal(name: "granted.b", sessionID: "granted-session", recordedAt: signalDate)])
        let next = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(next.load().map(\.name) == ["granted.b"])
    }

    /// A purge is not consent: it runs on a decline at launch, before anything
    /// was ever granted, so what it may leave behind is at most what was there.
    /// A directory that refuses the delete but holds no queue has nothing for
    /// the fallback to overwrite and nothing for a mark to stand in for.
    @Test(
        "A purge that cannot look inside the directory creates nothing there",
        .enabled(if: getuid() != 0, "root reaches a directory whose permissions refuse everyone")
    )
    func purgeInARefusingDirectoryWithNoQueueCreatesNothing() throws {
        let directory = try #require(TestTempDirectory.url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)

        let originalPermissions = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int ?? 0o755
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: directory.path
            )
        }

        storage.purge()

        try FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions],
            ofItemAtPath: directory.path
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// An erase outranks the read failure that suspended the writes: a decline
    /// has to reach the file whether or not this instance could read it, and
    /// the writes have to resume for whatever the next grant records.
    @Test(
        "An erase after an unreadable read still purges, and writing resumes",
        .enabled(if: getuid() != 0, "root reads a file whose permissions refuse everyone")
    )
    func purgeAfterAnUnreadableReadClearsTheBlock() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "pending.a", sessionID: "session-a", recordedAt: signalDate)])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        #expect(storage.load().isEmpty)

        storage.purge()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        storage.persist([Signal(name: "later.b", sessionID: "session-b", recordedAt: signalDate)])
        #expect(storage.load().map(\.name) == ["later.b"])
    }

    /// The mark is best effort too — the same refusal that stops the delete and
    /// the overwrite stops a sibling file from being created — so it cannot be
    /// the whole answer. The store that was told to erase has to refuse the
    /// restore itself for as long as it lives, which is the half that needs no
    /// filesystem.
    @Test(
        "A purge that cannot even leave a mark still restores nothing through the store that tried",
        .enabled(if: getuid() != 0, "root writes where the permissions refuse everyone")
    )
    func purgeThatCannotEvenMarkRestoresNothingThroughTheSameStore() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "declined.a", sessionID: "declined-session", recordedAt: signalDate)])

        let originalPermissions = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int ?? 0o755
        // Read-only file inside a read-only directory: the delete is refused by
        // the directory, the overwrite by the file, and a new sibling by the
        // directory again.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }

        storage.purge()

        // The fixture is the failure it claims: the queue is still on disk and
        // nothing was written beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            == ["aethergram-signal-queue.json"])
        #expect(try !JSONDecoder().decode([Signal].self, from: Data(contentsOf: fileURL)).isEmpty)

        #expect(storage.load().isEmpty)
    }

    /// A directory the process cannot reach answers the question "is there a
    /// queue file" with a no, which is the same answer as an empty container
    /// and means the opposite thing. Asking the read instead is what tells
    /// them apart, because only one of them comes back as a refusal.
    @Test(
        "A queue behind a directory that cannot be reached is not read as absent",
        .enabled(if: getuid() != 0, "root reaches a directory whose permissions refuse everyone")
    )
    func queueBehindAnUnreachableDirectoryIsNotReadAsAbsent() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "pending.a", sessionID: "session-a", recordedAt: signalDate)])

        let originalPermissions = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int ?? 0o755
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: directory.path
            )
        }

        #expect(storage.load().isEmpty)

        try FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions],
            ofItemAtPath: directory.path
        )
        storage.persist([Signal(name: "later.b", sessionID: "session-b", recordedAt: signalDate)])

        // The queue the unreachable directory hid is still first: read as
        // absent, the write would have replaced it.
        let readable = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(readable.load().map(\.name) == ["pending.a", "later.b"])
    }

    /// Suspending the writes is a state, not a verdict. A store that reads the
    /// file successfully afterwards knows what is there, so the reason to hold
    /// the writes off it is gone — and left standing it would cost the process
    /// every write it had left.
    @Test(
        "A read that succeeds later lifts the suspension the failed one left",
        .enabled(if: getuid() != 0, "root reads a file whose permissions refuse everyone")
    )
    func successfulReadLiftsTheSuspension() throws {
        let directory = try #require(TestTempDirectory.url)
        let signalDate = try testDate(year: 2026, month: 1, day: 5)
        let fileURL = directory.appendingPathComponent("aethergram-signal-queue.json")
        let storage = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        storage.persist([Signal(name: "pending.a", sessionID: "session-a", recordedAt: signalDate)])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        #expect(storage.load().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        #expect(storage.load().map(\.name) == ["pending.a"])

        storage.persist([Signal(name: "later.b", sessionID: "session-b", recordedAt: signalDate)])
        let readable = FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
        #expect(readable.load().map(\.name) == ["later.b"])
    }
}

@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// An awaited flush is one attempt at delivering what was queued when it was
/// called, and it returns promptly when cancelled. A host spends an expiring
/// window on it: a wait that grows with every later record, or that a held
/// lock or a slow disk keeps from seeing its cancel, outlasts the window.
///
/// Every hold here is released by a fallback timer as well as on the way
/// out, so a wait that ignores its bound fails under its own name rather
/// than as the suite's time limit.
@Suite("Flush contract", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.lifecycle))
struct FlushContractTests {
    /// How one attempt can be answered.
    enum Answer: CaseIterable, CustomTestStringConvertible {
        case delivered
        case permanent
        case retryable
        case noIdentity

        var testDescription: String {
            switch self {
            case .delivered: "delivered"
            case .permanent: "permanently rejected"
            case .retryable: "retryable"
            case .noIdentity: "no identity resolves"
            }
        }

        var outcome: TransportOutcome {
            switch self {
            case .delivered, .noIdentity: .delivered
            case .permanent: .permanent(reason: "rejected")
            case .retryable: .retryable(reason: "offline")
            }
        }

        var leavesTheQueue: Bool {
            self == .delivered || self == .permanent
        }
    }

    /// What ends a wait from outside it.
    enum Interruption: CaseIterable, CustomTestStringConvertible {
        case reset
        case decline
        case resetClosingCollection

        var testDescription: String {
            switch self {
            case .reset: "a reset"
            case .decline: "a decline"
            case .resetClosingCollection: "a reset that closes collection"
            }
        }
    }

    @Test("An awaited flush returns once its one attempt is answered, whatever the answer", arguments: Answer.allCases)
    func awaitedFlushReturnsOnTheAttemptsAnswer(answer: Answer) async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = SpyTransport(defaultOutcome: answer.outcome)
        let recorder = try SignalRecorder(
            configuration: testConfiguration(transmitInterval: 3600),
            transport: transport,
            queueStorage: RecordingQueueStorage(directory: directory),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { answer == .noIdentity ? nil : "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4)),
            retryDelay: { _ in 3600 }
        )
        recorder.updateConsent(.granted)
        recorder.record("Game.started")

        let elapsed = await ContinuousClock().measure { #expect(await flushReturns(recorder)) }

        #expect(elapsed < .seconds(5))
        #expect(transport.sendCount == (answer == .noIdentity ? 0 : 1))
        #expect((recorder.secondsUntilRetry == 0) == answer.leavesTheQueue)
    }

    /// A host that records from a background task while it flushes would
    /// otherwise wait for a queue that never empties.
    @Test("Recording continuously from another thread does not extend an awaited flush")
    func continuousRecordingDoesNotExtendTheWait() async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = SlowTransport(pause: .milliseconds(20))
        let recorder = try SignalRecorder(
            configuration: testConfiguration(batchSize: 5, transmitInterval: 3600),
            transport: transport,
            queueStorage: RecordingQueueStorage(directory: directory),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        recorder.updateConsent(.granted)
        recorder.record("first")
        let stop = SharedFlag()
        let stopped = Gate()
        DispatchQueue.global().async {
            // Bounded, so a wait that does grow ends and fails the bound below.
            let deadline = Date().addingTimeInterval(5)
            while !stop.isRaised, Date() < deadline {
                recorder.record("later")
                usleep(500)
            }
            stopped.open()
        }
        defer { stop.raise() }

        let elapsed = await ContinuousClock().measure { #expect(await flushReturns(recorder)) }
        stop.raise()
        await stopped.wait()

        #expect(elapsed < .seconds(3))
        #expect(transport.sentSignalNames.first == "first")
    }

    /// Records made after the call can push the flushed signals out of a full
    /// queue. Those have left it, and the wait is for what was queued at the
    /// call, not for what replaced it.
    @Test("An awaited flush returns once overflow has evicted part of what it was waiting on and the rest is sent")
    func evictionOfPartOfThePrefixEndsTheWait() async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = NamedHoldTransport(holding: ["a", "d"])
        defer { transport.releaseAll() }
        let recorder = try makeRecorder(
            directory: directory,
            transport: transport,
            configuration: testConfiguration(batchSize: 1, queueLimit: 3, transmitInterval: 3600)
        )
        recorder.updateConsent(.granted)
        for name in ["a", "b", "c"] {
            recorder.record(name)
        }

        let returned = Gate()
        let waiting = Task {
            await recorder.flushAndWait()
            returned.open()
        }
        await transport.held("a").wait()
        // The flush notes its queue in the call that registers it, while
        // nothing holds the recorder's lock; the records below come after.
        await waitUntil { recorder.flushWaiterCount == 1 }
        // Two later records push "a" and "b" out of a queue of three.
        recorder.record("d")
        recorder.record("e")
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) { transport.release("d") }
        let clock = ContinuousClock()
        let released = clock.now
        transport.release("a")
        // Bounded, and the flush cancelled after, so one that never returns
        // fails the bound below instead of holding the run open.
        await waitUntil(within: 5) { returned.isOpen }
        let elapsed = released.duration(to: clock.now)
        #expect(await ends(waiting))

        #expect(elapsed < .seconds(2))
        #expect(transport.sentSignalNames.prefix(2) == ["a", "c"])
    }

    @Test("An awaited flush returns when the queue it waits on is erased", arguments: Interruption.allCases)
    func eraseMidWaitEndsTheWait(interruption: Interruption) async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = HeldFirstSendTransport()
        defer { transport.release() }
        let recorder = try makeRecorder(directory: directory, transport: transport)
        recorder.updateConsent(.granted)
        recorder.record("Game.started")

        let returned = Gate()
        let waiting = Task {
            await recorder.flushAndWait()
            returned.open()
        }
        await transport.firstSendHeld.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) { transport.release() }
        let clock = ContinuousClock()
        let erased = clock.now
        DispatchQueue.global().async {
            switch interruption {
            case .reset: recorder.reset()
            case .decline: recorder.updateConsent(.declined)
            case .resetClosingCollection: recorder.resetClosingCollection {}
            }
        }
        // Bounded, and the flush cancelled after, so one that never returns
        // fails the bound below instead of holding the run open.
        await waitUntil(within: 5) { returned.isOpen }
        let elapsed = erased.duration(to: clock.now)
        #expect(await ends(waiting))

        #expect(elapsed < .seconds(1))
    }

    /// The removal is what stops a later process sending the batch again,
    /// so a flush that returns before it reaches the store returns before
    /// the delivery is settled.
    @Test("An awaited flush returns only once the removal of what it delivered has reached the store")
    func awaitedFlushWaitsForTheRemovalCheckpoint() async throws {
        let storage = GatedQueueStorage()
        let transport = SpyTransport()
        let recorder = try SignalRecorder(
            configuration: testConfiguration(transmitInterval: 3600),
            transport: transport,
            queueStorage: storage,
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        recorder.updateConsent(.granted)
        recorder.record("Game.started")
        await recorder.writer.awaitPendingWrites()
        storage.holdPersist()
        defer { storage.releasePersist() }

        let returned = Gate()
        let waiting = Task {
            await recorder.flushAndWait()
            returned.open()
        }
        await storage.persistEntered.wait()
        try await Task.sleep(for: .milliseconds(200))
        let returnedBeforeTheRemovalLanded = returned.isOpen
        storage.releasePersist()
        let returnedOnceItLanded = await ends(waiting)

        #expect(!returnedBeforeTheRemovalLanded)
        #expect(returnedOnceItLanded)

        #expect(transport.sentSignalNames == ["Game.started"])
        #expect(storage.signals.isEmpty)
    }

    /// A checkpoint the store failed to write leaves the delivered batch on
    /// disk, and the next process sends it again. That is the delivery
    /// guarantee: at least once.
    @Test("A removal the store failed to write is sent again by the next process")
    func failedRemovalCheckpointResendsAfterRestart() async throws {
        let directory = try #require(TestTempDirectory.url)
        FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem)
            .persist(["first", "second", "third"].map(Self.queued))
        let operations = FaultingFileOperations()
        // The removal rewrites the file; nothing before it does.
        operations.script(.replace, .refuse(CocoaError(.fileWriteOutOfSpace)))
        do {
            let transport = SpyTransport(outcomes: [.delivered], defaultOutcome: .retryable(reason: "offline"))
            let recorder = try SignalRecorder(
                configuration: testConfiguration(batchSize: 2, transmitInterval: 3600),
                transport: transport,
                queueStorage: FileSignalQueueStorage(
                    directory: directory,
                    logSubsystem: testLogSubsystem,
                    operations: operations
                ),
                retentionStore: SpyRetentionStore(),
                clientUserProvider: { "client-user" },
                environmentProvider: { [:] },
                calendar: testCalendar,
                now: steppingClock(from: testDate(year: 2026, month: 3, day: 4)),
                retryDelay: { _ in 3600 }
            )
            recorder.updateConsent(.granted)
            #expect(await flushReturns(recorder))
            await waitUntil { transport.sendCount == 2 }
            await recorder.writer.awaitPendingWrites()

            #expect(transport.sentSignalNames == ["first", "second", "third"])
            #expect(operations.writes.contains(.replace))
        }

        let transport = SpyTransport()
        let reborn = try SignalRecorder(
            configuration: testConfiguration(transmitInterval: 3600),
            transport: transport,
            queueStorage: FileSignalQueueStorage(directory: directory, logSubsystem: testLogSubsystem),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 5))
        )
        reborn.updateConsent(.granted)
        #expect(await flushReturns(reborn))

        #expect(transport.sentSignalNames == ["first", "second", "third"])
    }

    // MARK: Cancellation

    /// Held seams that each park something a flush could otherwise end up
    /// waiting behind: the recorder's lock, the writer, the network.
    enum Held: CaseIterable, CustomTestStringConvertible {
        case restore
        case clientUser
        case writer
        case transport

        var testDescription: String {
            switch self {
            case .restore: "a held restore"
            case .clientUser: "a held identifier provider"
            case .writer: "a held queue writer"
            case .transport: "a held send"
            }
        }
    }

    @Test("Cancelling an awaited flush returns promptly", arguments: Held.allCases)
    func cancellationReturnsPromptly(held: Held) async throws {
        let directory = try #require(TestTempDirectory.url)
        let storage = GatedQueueStorage(seed: [Self.restored])
        let clientUser = HeldClientUser()
        let transport = HeldFirstSendTransport()
        let recorder = try SignalRecorder(
            configuration: testConfiguration(transmitInterval: 3600),
            transport: transport,
            queueStorage: held == .restore || held == .writer ? storage : RecordingQueueStorage(directory: directory),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: clientUser.provider,
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        let releaseAll: @Sendable () -> Void = {
            storage.releaseLoad()
            storage.releasePersist()
            clientUser.release()
            transport.release()
        }
        defer { releaseAll() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) { releaseAll() }

        switch held {
        case .restore:
            storage.holdLoad()
            DispatchQueue.global().async { recorder.updateConsent(.granted) }
            await storage.loadEntered.wait()
        case .clientUser:
            recorder.updateConsent(.granted)
            recorder.record("Game.started")
            clientUser.hold()
            // A drain already resolving the identifier holds the lock.
            recorder.flush()
            await clientUser.entered.wait()
        case .writer:
            recorder.updateConsent(.granted)
            // The writer's queue blocks on a write submitted before the call.
            storage.holdPersist()
            recorder.record("Game.started")
            await storage.persistEntered.wait()
        case .transport:
            recorder.updateConsent(.granted)
            recorder.record("Game.started")
        }
        try await cancelAndMeasure(recorder)
    }

    /// A host that flushes on every deactivation and cancels on every
    /// expiry would otherwise grow the registry by one waiter each time.
    @Test("Cancelled awaited flushes leave no waiter registered")
    func cancelledFlushesLeaveNoWaiterBehind() async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = HeldFirstSendTransport()
        defer { transport.release() }
        let recorder = try makeRecorder(directory: directory, transport: transport)
        recorder.updateConsent(.granted)
        recorder.record("Game.started")
        recorder.flush()
        await transport.firstSendHeld.wait()

        let flushes = (0 ..< 100).map { _ in Task { await recorder.flushAndWait() } }
        await waitUntil { recorder.flushWaiterCount == 100 }
        let registered = recorder.flushWaiterCount
        for flush in flushes {
            flush.cancel()
        }
        // One bound for all of them, not one each.
        let allReturned = await ends(Task {
            for flush in flushes {
                await flush.value
            }
        })

        #expect(allReturned)
        #expect(registered == 100)
        #expect(recorder.flushWaiterCount == 0)
    }

    /// `withTaskCancellationHandler` runs the handler at once for a task
    /// already cancelled, before anything is registered for it to find.
    @Test("An awaited flush called from a task already cancelled returns promptly")
    func cancelledBeforeRegistrationReturnsPromptly() async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = HeldFirstSendTransport()
        defer { transport.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) { transport.release() }
        let recorder = try makeRecorder(directory: directory, transport: transport)
        recorder.updateConsent(.granted)
        recorder.record("Game.started")
        recorder.flush()
        await transport.firstSendHeld.wait()

        let clock = ContinuousClock()
        let started = clock.now
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await recorder.flushAndWait()
        }
        let returned = await ends(waiting, within: 1)

        #expect(returned)
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    // MARK: Private

    private static let restored = queued("restored")

    private static func queued(_ name: String) -> Signal {
        Signal(
            name: name,
            parameters: [:],
            floatValue: nil,
            sessionID: "restored-session",
            recordedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    private func makeRecorder(
        directory: URL,
        transport: any SignalTransport,
        configuration: AethergramConfiguration = testConfiguration(transmitInterval: 3600)
    ) throws -> SignalRecorder {
        try SignalRecorder(
            configuration: configuration,
            transport: transport,
            queueStorage: RecordingQueueStorage(directory: directory),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
    }

    /// Starts a flush, cancels it once it has had time to reach whatever
    /// is held, and bounds how long the cancel takes to return it.
    private func cancelAndMeasure(_ recorder: SignalRecorder) async throws {
        let waiting = Task { await recorder.flushAndWait() }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let cancelled = clock.now
        waiting.cancel()
        let returned = await ends(waiting, within: 1)
        #expect(returned)
        #expect(cancelled.duration(to: clock.now) < .seconds(1))
    }
}

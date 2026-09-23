@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// A host brackets delivery with an expiring-activity window: begin, flush,
/// end. A flush that returns before the request starts ends the window with
/// the batch still unsent, and one that waits for writes nobody asked it to
/// wait for may outlast the window it was given.
///
/// The time limit is the bound on every wait here: a flush that never
/// returns has to fail under its own name.
@Suite("Awaited flush", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.lifecycle))
struct AwaitedFlushTests {
    /// What nothing can send. A withheld answer sends nothing, an empty queue
    /// has nothing, and a retry a failure owes is not the flush's to hurry.
    enum NothingToSend: CaseIterable, CustomTestStringConvertible {
        case consentWithheld
        case queueEmpty
        case retryOwed

        var testDescription: String {
            switch self {
            case .consentWithheld: "consent withheld"
            case .queueEmpty: "queue empty"
            case .retryOwed: "retry owed"
            }
        }
    }

    @Test("An awaited flush returns only once the send it started has been answered")
    func awaitedFlushReturnsAfterTheSendIsAnswered() async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = SlowTransport(pause: .milliseconds(300))
        let recorder = try makeRecorder(directory: directory, transport: transport)
        recorder.updateConsent(.granted)
        // An hour's coalescing wait, so nothing but the flush sends this.
        recorder.record("Game.started")

        #expect(await flushReturns(recorder))

        #expect(transport.answeredCount == 1)
        #expect(transport.sentSignalNames == ["Game.started"])
    }

    /// A drain already sending when the flush arrives cannot be hurried, and
    /// the record made while it sends is one the flush was called after. What
    /// the flush owes is that record too, whether the running drain carries it
    /// or one the flush starts once that drain ends.
    @Test("An awaited flush behind a running drain returns with what was recorded before it sent")
    func awaitedFlushBehindARunningDrainCarriesTheLaterRecord() async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = HeldFirstSendTransport()
        defer { transport.release() }
        let recorder = try makeRecorder(directory: directory, transport: transport)
        recorder.updateConsent(.granted)
        recorder.record("first")
        recorder.flush()
        await transport.firstSendHeld.wait()
        recorder.record("second")

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { transport.release() }
        #expect(await flushReturns(recorder))

        #expect(transport.sentSignalNames == ["first", "second"])
    }

    @Test("An awaited flush returns at once when nothing can be sent", arguments: NothingToSend.allCases)
    func awaitedFlushReturnsPromptlyWhenNothingCanBeSent(reason: NothingToSend) async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = SpyTransport(defaultOutcome: .retryable(reason: "offline"))
        let recorder = try makeRecorder(directory: directory, transport: transport)
        switch reason {
        case .consentWithheld:
            recorder.updateConsent(.declined)
            recorder.record("Game.started")
        case .queueEmpty:
            recorder.updateConsent(.granted)
        case .retryOwed:
            recorder.updateConsent(.granted)
            recorder.record("Game.started")
            // The failure owes two hours before the next attempt.
            await recorder.drain()
        }
        let sentBefore = transport.sendCount

        let clock = ContinuousClock()
        let elapsed = await clock.measure { #expect(await flushReturns(recorder)) }

        #expect(elapsed < .seconds(5))
        #expect(transport.sendCount == sentBefore)
    }

    /// The window a host brackets delivery with can expire, and the handler
    /// that ends it cancels the task waiting in the flush. That wait ends; the
    /// send it was waiting on does not, because the batch it carries is on
    /// disk either way and a cancelled send would only have to be made again.
    @Test("Cancelling an awaited flush ends the wait and leaves the send to finish")
    func cancellingAnAwaitedFlushEndsTheWaitButNotTheSend() async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = HeldFirstSendTransport()
        defer { transport.release() }
        let recorder = try makeRecorder(directory: directory, transport: transport)
        recorder.updateConsent(.granted)
        recorder.record("Game.started")

        let waiting = Task { await recorder.flushAndWait() }
        await transport.firstSendHeld.wait()
        waiting.cancel()
        #expect(await ends(waiting, within: 1))

        transport.release()
        await waitUntil { recorder.drainsScheduled >= 1 && transport.sendCount == 1 }
        #expect(transport.sentSignalNames == ["Game.started"])
    }

    /// A grant onto a queue a killed process left is the one moment nothing
    /// else schedules its delivery: nothing has been recorded yet, and an
    /// extension may record nothing before it is suspended again.
    @Test("A grant onto a queue a killed process left schedules its delivery")
    func grantOntoARestoredQueueSchedulesDelivery() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 3, day: 4)
        let dead = makeFixture(directory: directory, now: steppingClock(from: start))
        dead.recorder.updateConsent(.granted)
        dead.recorder.record("survivor")
        await dead.recorder.writer.awaitPendingWrites()

        let reborn = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 0.05),
            now: steppingClock(from: start.addingTimeInterval(60))
        )
        reborn.recorder.updateConsent(.granted)
        await waitUntil { reborn.transport.sendCount == 1 }
        withExtendedLifetime(reborn.recorder) {}

        #expect(reborn.recorder.drainsScheduled >= 1)
        #expect(reborn.transport.sentSignalNames == ["survivor"])
    }

    /// The other half: a grant with nothing to send wakes nothing.
    @Test("A grant onto an empty queue schedules nothing")
    func grantOntoAnEmptyQueueSchedulesNothing() throws {
        let directory = try #require(TestTempDirectory.url)
        let fixture = try makeFixture(
            directory: directory,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        fixture.recorder.updateConsent(.granted)

        #expect(fixture.recorder.drainsScheduled == 0)
    }

    // MARK: Private

    private func makeRecorder(directory: URL, transport: any SignalTransport) throws -> SignalRecorder {
        try SignalRecorder(
            configuration: testConfiguration(transmitInterval: 3600),
            transport: transport,
            queueStorage: RecordingQueueStorage(directory: directory),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
    }
}

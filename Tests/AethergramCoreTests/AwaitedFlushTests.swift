@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// A host ends a session and flushes on its way out, then is suspended. A
/// flush that returns before its pass has sent, or before the queue writes
/// it was called after have landed, leaves the batch unsent or the record
/// off disk; one that hurries a retry, or sends with the gate shut, breaks
/// the schedule or the consent it answers to; one a cancel cannot end
/// outlasts the time the host was given.
///
/// Every wait is bounded, so a flush that never returns fails under its own
/// name rather than as the suite's time limit.
@Suite("Awaited flush", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.lifecycle))
struct AwaitedFlushTests {
    /// What erases the queue while a pass is sending.
    enum Erase: CaseIterable, CustomTestStringConvertible {
        case reset
        case decline

        var testDescription: String {
            switch self {
            case .reset: "a reset"
            case .decline: "a decline"
            }
        }
    }

    @Test("An awaited flush returns only after its pass's send is answered and its removal is written")
    func returnsAfterTheSendAndTheWrite() async throws {
        let transport = SlowTransport(pause: .milliseconds(300))
        let storage = GatedQueueStorage()
        let recorder = try makeRecorder(transport: transport, storage: storage)
        recorder.updateConsent(.granted)
        // An hour's coalescing wait, so nothing but the flush sends this.
        recorder.record("a")

        #expect(await flushReturns(recorder))

        #expect(transport.answeredCount == 1)
        #expect(storage.signals.isEmpty)
    }

    @Test("A record made before an awaited flush is on disk when the flush returns")
    func recordBeforeTheCallIsOnDiskAtReturn() async throws {
        let storage = GatedQueueStorage()
        let recorder = try makeRecorder(
            transport: SpyTransport(defaultOutcome: .retryable(reason: "offline")),
            storage: storage
        )
        recorder.updateConsent(.granted)
        storage.holdPersist()
        defer { storage.releasePersist() }
        recorder.record("a")
        await storage.persistEntered.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { storage.releasePersist() }

        #expect(await flushReturns(recorder))

        #expect(storage.signals.map(\.name) == ["a"])
    }

    /// The retry is the endpoint's to be owed, and a flush on the host's
    /// cadence that could hurry it would damp nothing.
    @Test("An awaited flush with a retry owed sends nothing and does not wait out the backoff")
    func retryOwedIsNotHurriedOrWaitedOut() async throws {
        let transport = SpyTransport(defaultOutcome: .retryable(reason: "offline"))
        let recorder = try makeRecorder(transport: transport, storage: GatedQueueStorage())
        recorder.updateConsent(.granted)
        recorder.record("a")
        await recorder.drain()
        try #require(recorder.secondsUntilRetry > 60)

        #expect(await flushReturns(recorder, within: 1))

        #expect(transport.sendCount == 1)
    }

    /// Before a grant there is nothing a flush may do but cross the writer
    /// barrier: no drain, no read of the queue, no identifier, no send.
    @Test("An awaited flush without a grant schedules, reads, resolves, and sends nothing", arguments: [
        ConsentState.neverAsked, .declined
    ])
    func notGrantedTouchesNoLayer(consent: ConsentState) async throws {
        let fixture = try makeGatedFixture()
        if consent != .neverAsked { fixture.recorder.updateConsent(consent) }
        fixture.recorder.record("a")

        #expect(await flushReturns(fixture.recorder, within: 1))

        #expect(fixture.transport.sendCount == 0)
        #expect(fixture.recorder.drainsScheduled == 0)
        #expect(fixture.storage.loadCallCount == 0)
        #expect(fixture.clientUserCalls.count == 0)
    }

    /// The rotation's callback is the host's, on its own thread. A flush
    /// from elsewhere meanwhile has nothing it may send, and must not be
    /// held until the rotation ends.
    @Test("An awaited flush while collection is closed for a reset sends nothing and returns")
    func closedForResetSendsNothing() async throws {
        let fixture = try makeGatedFixture()
        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("before")
        let inside = Gate()
        let release = DispatchSemaphore(value: 0)
        let resetDone = Gate()
        DispatchQueue.global().async {
            fixture.recorder.resetClosingCollection {
                inside.open()
                release.wait()
            }
            resetDone.open()
        }
        await inside.wait()
        let drainsBefore = fixture.recorder.drainsScheduled
        let resolvedBefore = fixture.clientUserCalls.count

        let returned = await flushReturns(fixture.recorder, within: 1)
        let drainsAfter = fixture.recorder.drainsScheduled
        release.signal()
        await resetDone.wait()

        #expect(returned)
        #expect(drainsAfter == drainsBefore)
        #expect(fixture.clientUserCalls.count == resolvedBefore)
        #expect(fixture.transport.sendCount == 0)
    }

    /// The erase cancels the pass, and a transport that honours
    /// cancellation, as `URLSession` does, ends the send, so the wait ends
    /// with it.
    @Test("An erase while an awaited flush's pass is sending ends the wait", arguments: Erase.allCases)
    func eraseMidSendEndsTheWait(erase: Erase) async throws {
        let transport = HeldUntilCancelledTransport()
        let recorder = try makeRecorder(transport: transport, storage: GatedQueueStorage())
        recorder.updateConsent(.granted)
        recorder.record("a")
        let waiting = Task { await recorder.flushAndWait() }
        await transport.entered.wait()

        switch erase {
        case .reset: recorder.reset()
        case .decline: recorder.updateConsent(.declined)
        }

        #expect(await ends(waiting, within: 5))
    }

    /// The host's time can run out while the send is still out. The send
    /// here ignores cancellation, so only the flush's own race ends the wait.
    @Test("Cancelling an awaited flush while the transport holds its send returns within a second")
    func cancellationReturnsPromptly() async throws {
        let transport = HeldFirstSendTransport()
        defer { transport.release() }
        let recorder = try makeRecorder(transport: transport, storage: GatedQueueStorage())
        recorder.updateConsent(.granted)
        recorder.record("a")
        let waiting = Task { await recorder.flushAndWait() }
        await transport.firstSendHeld.wait()

        waiting.cancel()

        #expect(await ends(waiting, within: 1))
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

    private func makeRecorder(
        transport: any SignalTransport,
        storage: any SignalQueueStorage
    ) throws -> SignalRecorder {
        try SignalRecorder(
            configuration: testConfiguration(transmitInterval: 3600),
            transport: transport,
            queueStorage: storage,
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
    }

    private func makeGatedFixture() throws -> RecorderFixture {
        let directory = try #require(TestTempDirectory.url)
        return try AethergramCoreTests.makeFixture(
            directory: directory,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
    }
}

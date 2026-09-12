@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// Delivery has to happen while the host is alive.
///
/// The first sim walk of this transport found the queue growing and never
/// emptying: `drain()` had exactly two callers, a resign-time flush and a retry
/// that only fires after a failure that never happened. An app extension has no
/// background execution and is suspended moments after resigning, and a compact
/// collapse delivers no resign event at all, so the one delivery path almost
/// never completed. Ten signals sat queued through two minutes of active use.
///
/// **What this suite does not assert, and why.** How soon a scheduled task runs
/// is nobody's to promise here. These tests share a cooperative thread pool
/// with every suite beside them, and a task created while something saturates
/// it can go unscheduled for as long as that lasts — measured once against
/// CPU-bound fill benchmarks the package no longer contains: the test that
/// asserted a scheduled delivery failed roughly three runs in four inside the
/// full suite while passing twenty for twenty in isolation, with the transport
/// never called rather than called late. So the coverage splits three ways: the
/// delay decision is pinned pool-free by
/// `AethergramConfiguration.deliveryDelay`, the work a drain performs is pinned
/// by driving `drain()` from the test's own task, and the latency of a
/// scheduled task is left to a runtime walk against a live host process.
///
/// **What the two scheduling tests do assert.** Whether the recorder schedules
/// anything at all, and roughly how often, has no other observer: the drain
/// slot is private, and a task that was never created looks exactly like one
/// the pool has not reached. One polls to a deadline far longer than the
/// interval it waits on; the other counts wake-ups inside a window and bounds
/// them on both sides, because too few and too many are different defects. A
/// pool busy enough to starve either would read as a failure, which is the
/// price of asserting this at all.
///
/// The time limit is the outer bound on those polls: a pool starved badly
/// enough never to run the scheduled task must name the test rather than stall
/// the run until a runner is cancelled.
@Suite("Delivery scheduling", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.lifecycle))
struct DeliverySchedulingTests {
    /// The scheduler sits inside the consent gate. A drain scheduled while the
    /// answer is withheld would resolve the identifier the gate exists to keep
    /// unminted, even if the send itself went nowhere.
    @Test("No drain is scheduled while consent is withheld", arguments: [ConsentState.neverAsked, .declined])
    func withheldConsentSchedulesNothing(state: ConsentState) async throws {
        let directory = try #require(TestTempDirectory.url)
        let fixture = try makeFixture(
            directory: directory,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        fixture.recorder.updateConsent(state)
        fixture.recorder.record("Game.started")
        // `flush()` asks for a drain at zero delay whatever the interval is, so
        // the schedule this asserts against is the hurried one.
        fixture.recorder.flush()
        // Driving the drain directly is the stronger form of this
        // assertion: even handed the work, a withheld answer sends nothing.
        await fixture.recorder.drain()

        #expect(fixture.transport.sendCount == 0)
        #expect(!fixture.clientUserCalls.wasCalled)
        #expect(!fixture.environmentCalls.wasCalled)
    }

    /// What the walk proved by killing the process, asserted here without one:
    /// a signal recorded by a previous life goes out on the next activation,
    /// through the same door the consumer calls on `willBecomeActive`.
    ///
    /// The coalescing interval is long, so the task each recorder schedules is
    /// still asleep and cannot race the drain this test drives itself.
    @Test("A queue left by a dead process drains on the next activation")
    func inheritedQueueDrainsOnActivation() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 3, day: 4)
        let dead = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            now: steppingClock(from: start)
        )
        dead.recorder.updateConsent(.granted)
        dead.recorder.record("survivor")
        // The dead process's write is what the next one inherits, so it has
        // to reach disk before that process is abandoned.
        dead.recorder.writer.waitForPendingWrites()
        #expect(dead.transport.sendCount == 0)
        #expect(dead.storage.signalsOnDisk.count == 1)

        // A new recorder over the same directory is the next process.
        let reborn = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            now: steppingClock(from: start.addingTimeInterval(60))
        )
        reborn.recorder.updateConsent(.granted)
        await reborn.recorder.drain()

        #expect(reborn.transport.sentSignalNames == ["survivor"])
        #expect(reborn.storage.signalsOnDisk.isEmpty)
    }

    /// A decline landing between the record and the send stops delivery, and
    /// takes the queue with it rather than leaving it for a later grant.
    @Test("A decline mid-cycle stops delivery and erases the batch")
    func declineMidCycleStopsDelivery() async throws {
        let directory = try #require(TestTempDirectory.url)
        let fixture = try makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("Game.started")
        fixture.recorder.updateConsent(.declined)
        await fixture.recorder.drain()

        #expect(fixture.transport.sendCount == 0)
        #expect(fixture.storage.signalsOnDisk.isEmpty)
    }

    /// A record landing while a drain is running schedules nothing: the slot
    /// says running, and a second task would send the batch already in flight
    /// a second time. The running drain has to take that signal, and when it
    /// ends without having taken it, the release is the last moment anything
    /// can be scheduled for it — otherwise it waits for a record or a flush
    /// the consumer may never make.
    ///
    /// The record lands inside the send of the batch the drain turns out to end
    /// on, which is the latest point a test can reach: between that batch's
    /// verdict and the release there is no seam to hold. Withholding the
    /// identifier from the claim that follows is what makes the miss
    /// deterministic instead of a race — it is exactly the claim the late
    /// signal would have ridden.
    @Test("A signal recorded while a drain is finishing is delivered without another record")
    func signalRecordedDuringADrainIsDeliveredByTheRestart() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 3, day: 4)
        let transport = MidSendTransport()
        let claims = Counter()
        let recorder = SignalRecorder(
            configuration: testConfiguration(transmitInterval: 0.05),
            transport: transport,
            queueStorage: RecordingQueueStorage(directory: directory),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { claims.nextIndex() == 1 ? nil : "client-user" },
            environmentProvider: { ["env.key": "env-value"] },
            calendar: testCalendar,
            now: steppingClock(from: start)
        )
        // Runs inside the first send, so the record lands while the slot
        // holds this drain and can schedule nothing of its own.
        transport.duringFirstSend = { recorder.record("late") }

        recorder.updateConsent(.granted)
        recorder.record("first")
        // Nothing past this line records or flushes, so the only thing that
        // can deliver "late" is a drain the recorder scheduled for itself.
        await waitUntil { transport.sendCount == 2 }
        // A scheduled drain holds the recorder weakly, so across the wait this
        // local is the only thing keeping it alive to be delivered from.
        withExtendedLifetime(recorder) {}

        #expect(transport.sentSignals.map(\.name) == ["first", "late"])
    }

    /// A backoff any flush can skip is not a backoff.
    ///
    /// `flush()` asks for a drain at zero delay, and so does a record that
    /// fills the batch. Both happen on the consumer's own cadence — an app
    /// extension flushes once per activation — so a zero-delay request that
    /// preempts the wait after a failure retries a refusing endpoint as often
    /// as the app is used, which is the thing the interval exists to stop.
    ///
    /// The window is the failing half of the decision the test below makes:
    /// 300ms is far inside the two seconds the first failure buys, and far
    /// outside the milliseconds a preempted drain takes to reach the transport.
    @Test("A flush during a backoff does not hurry the retry")
    func flushDuringABackoffDoesNotHurryTheRetry() async throws {
        let directory = try #require(TestTempDirectory.url)
        let fixture = try makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 1),
            transport: SpyTransport(defaultOutcome: .retryable(reason: "offline")),
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("Game.started")
        // The failure is what arms the backoff: one doubling out, the next
        // attempt is owed two seconds from here.
        await fixture.recorder.drain()
        #expect(fixture.transport.sendCount == 1)

        fixture.recorder.flush()
        try await Task.sleep(for: .milliseconds(300))
        // A scheduled drain holds the recorder weakly, so this local is what
        // keeps one alive to have sent anything across the window.
        withExtendedLifetime(fixture.recorder) {}

        #expect(fixture.transport.sendCount == 1)
    }

    /// The other half of that decision, so the fix cannot be "hurry nothing":
    /// with no retry owed, a flush still collapses the coalescing wait it
    /// exists to collapse.
    @Test("A flush with no retry owed still hurries the coalescing wait")
    func flushWithNoRetryOwedStillHurriesTheWait() async throws {
        let directory = try #require(TestTempDirectory.url)
        let fixture = try makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        fixture.recorder.updateConsent(.granted)
        // An hour out, so nothing but the flush can deliver this.
        fixture.recorder.record("Game.started")
        fixture.recorder.flush()
        await waitUntil { fixture.transport.sendCount == 1 }
        withExtendedLifetime(fixture.recorder) {}

        #expect(fixture.transport.sentSignalNames == ["Game.started"])
    }

    /// A host that cannot resolve an identifier yet halts every drain before
    /// the claim, and the restart keys on a queue that is not empty — which
    /// stays true for as long as the identifier is missing. Counting the halt
    /// as a failure is what keeps that from costing a wake-up at the steady
    /// interval for the life of the process.
    ///
    /// Bounded on both sides, because from one sample the two defects look
    /// alike: fewer than two wakes says the halt scheduled nothing at all,
    /// more than ten says nothing damped it — flat retries across this window
    /// would be roughly fifty, and the backoff makes five.
    @Test("A drain halted for want of an identifier backs off instead of waking at the interval")
    func haltedDrainBacksOffRatherThanWakingAtTheInterval() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 3, day: 4)
        let transport = SpyTransport()
        let claims = Counter()
        let recorder = SignalRecorder(
            configuration: testConfiguration(transmitInterval: 0.01),
            transport: transport,
            queueStorage: RecordingQueueStorage(directory: directory),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: {
                claims.increment()
                return nil
            },
            environmentProvider: { ["env.key": "env-value"] },
            calendar: testCalendar,
            now: steppingClock(from: start)
        )

        recorder.updateConsent(.granted)
        recorder.record("stranded")
        try await Task.sleep(for: .milliseconds(500))
        withExtendedLifetime(recorder) {}

        #expect(claims.count >= 2)
        #expect(claims.count <= 10)
        // The identifier is what the halt is for: nothing may leave without it.
        #expect(transport.sendCount == 0)
    }

    /// The invariant through the recorder rather than the pure
    /// functions: a process that dies without calling `endSession()` still
    /// contributes a duration, because the next activation closes its session
    /// from the persisted checkpoint.
    @Test("A session killed without an end call is closed by the next activation")
    func killedSessionIsClosedByTheNextActivation() throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 3, day: 4)
        let retention = SpyRetentionStore()

        // First process: open a session, record past the checkpoint interval,
        // then vanish. No endSession(), no flush, nothing.
        let dead = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            retention: retention,
            now: steppingClock(from: start, step: 30)
        )
        dead.recorder.updateConsent(.granted)
        dead.recorder.beginSession()
        dead.recorder.record("alpha")
        dead.recorder.record("beta")

        let afterKill = try #require(retention.record)
        #expect(afterKill.completedSessionsCount == 0)
        #expect(afterKill.openSessionStartedAt != nil)

        // Second process over the same store, an hour later.
        let reborn = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            retention: retention,
            now: steppingClock(from: start.addingTimeInterval(3600), step: 30)
        )
        reborn.recorder.updateConsent(.granted)
        reborn.recorder.beginSession()

        let afterRelaunch = try #require(retention.record)
        #expect(afterRelaunch.completedSessionsCount == 1)
        // The dead session's own activity span, not the hour it spent dead.
        #expect(afterRelaunch.totalSessionSeconds == 60)
        #expect(afterRelaunch.previousSessionSeconds == 60)
        #expect(afterRelaunch.totalSessionsCount == 2)
    }

    /// Two `beginSession()` calls land in one activation whenever consent is
    /// adopted from another device: the host grants on that arrival, before the
    /// cycle's own session emit. Without a guard the second call closes the
    /// first at a near-zero duration and counts the cycle twice, dragging the
    /// average down with a session nobody had.
    @Test("A second begin in the same activation leaves the open session alone")
    func repeatBeginInOneActivationIsIgnored() throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 3, day: 4)
        let retention = SpyRetentionStore()
        let fixture = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            retention: retention,
            now: steppingClock(from: start, step: 30)
        )

        fixture.recorder.updateConsent(.granted)
        // The consent grant opens one, then the cycle's own emit asks again.
        fixture.recorder.beginSession()
        let opened = try #require(retention.record?.openSessionStartedAt)
        fixture.recorder.beginSession()

        let after = try #require(retention.record)
        #expect(after.openSessionStartedAt == opened)
        #expect(after.totalSessionsCount == 1)
        #expect(after.completedSessionsCount == 0)
        #expect(after.previousSessionSeconds == nil)
    }

    /// The guard is keyed to this instance's own stamp, not to the mere
    /// presence of an open session — a process that died also leaves one open,
    /// and closing that is the whole point of the inference path.
    @Test("A new instance still closes a session the previous process left open")
    func guardDoesNotBlockInheritedSessions() throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 3, day: 4)
        let retention = SpyRetentionStore()

        let dead = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            retention: retention,
            now: steppingClock(from: start, step: 30)
        )
        dead.recorder.updateConsent(.granted)
        dead.recorder.beginSession()
        dead.recorder.record("alpha")

        let reborn = makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 3600),
            retention: retention,
            now: steppingClock(from: start.addingTimeInterval(600), step: 30)
        )
        reborn.recorder.updateConsent(.granted)
        reborn.recorder.beginSession()

        let after = try #require(retention.record)
        #expect(after.completedSessionsCount == 1)
        #expect(after.totalSessionsCount == 2)
    }
}

// MARK: - Waiting on scheduled work

/// Returns as soon as `condition` holds, and at the deadline regardless, so the
/// assertion that follows reports the state rather than a timeout. The deadline
/// is wall time: what is being waited on is a task the pool schedules, not
/// anything the recorder's own clock advances.
private func waitUntil(within seconds: TimeInterval = 10, _ condition: @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

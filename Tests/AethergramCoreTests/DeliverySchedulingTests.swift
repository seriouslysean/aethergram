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
/// **What this suite does not assert, and why.** Whether the task the recorder
/// schedules actually gets to run is not testable here. These tests share a
/// cooperative thread pool with CPU-bound fill benchmarks, and an unstructured
/// task created while those saturate it can go unscheduled for their whole
/// duration — measured, not assumed: whichever test asserted it failed roughly
/// three runs in four inside the full suite while passing twenty for twenty in
/// isolation, with the transport never called rather than called late. So the
/// coverage splits three ways: the delay decision is pinned pool-free by
/// `AethergramConfiguration.deliveryDelay`, the work a drain performs is pinned
/// by driving `drain()` from the test's own task, and that a scheduled task
/// runs at all is left to a runtime walk against a live host process.
@Suite("Delivery scheduling", .tempDirectory, .serialized, .tags(.lifecycle))
struct DeliverySchedulingTests {
    /// The scheduler sits inside the consent gate. A drain scheduled while the
    /// answer is withheld would resolve the identifier the gate exists to keep
    /// unminted, even if the send itself went nowhere.
    @Test("No drain is scheduled while consent is withheld", arguments: [ConsentState.neverAsked, .declined])
    func withheldConsentSchedulesNothing(state: ConsentState) async throws {
        let directory = try #require(TestTempDirectory.url)
        let fixture = try makeFixture(
            directory: directory,
            configuration: testConfiguration(transmitInterval: 0),
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        fixture.recorder.updateConsent(state)
        fixture.recorder.record("Game.started")
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
    /// adopted from another device: `reconcileSyncedPreferences` grants before
    /// the cycle's own session emit. Without a guard the second call closes the
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

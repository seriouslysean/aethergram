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
}

@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// The retry schedule is a pure function precisely so it can be asserted
/// without waiting for it.
@Suite("Transmission backoff")
struct BackoffTests {
    /// `transmitInterval * 2^failures`, capped at `maxBackoffInterval`. With
    /// the shipped defaults of 10s and 300s the cap lands between the fourth
    /// and fifth failure, which is the row that proves the cap is applied
    /// rather than merely declared.
    @Test(
        "Backoff doubles per failure and stops at the ceiling",
        arguments: [
            (0, 10.0),
            (1, 20.0),
            (2, 40.0),
            (3, 80.0),
            (4, 160.0),
            (5, 300.0),
            (12, 300.0)
        ]
    )
    func backoffDoublesAndCaps(failures: Int, expected: TimeInterval) {
        let configuration = AethergramConfiguration(logSubsystem: testLogSubsystem)
        #expect(configuration.backoffInterval(consecutiveFailures: failures) == expected)
    }

    /// Zero and below both mean "no failure yet", so both return the steady
    /// interval. Without the guard a negative count would halve the delay below
    /// the floor the schedule promises.
    @Test("A non-positive failure count returns the steady interval")
    func nonPositiveFailureCountReturnsTheSteadyInterval() {
        let configuration = AethergramConfiguration(logSubsystem: testLogSubsystem)
        #expect(configuration.backoffInterval(consecutiveFailures: 0) == configuration.transmitInterval)
        #expect(configuration.backoffInterval(consecutiveFailures: -1) == configuration.transmitInterval)
        #expect(configuration.backoffInterval(consecutiveFailures: .min) == configuration.transmitInterval)
    }

    /// A custom interval scales from its own base, not from the default.
    @Test("Backoff scales from the configured interval")
    func backoffScalesFromTheConfiguredInterval() {
        let configuration = testConfiguration(transmitInterval: 5, maxBackoffInterval: 25)
        #expect(configuration.backoffInterval(consecutiveFailures: 1) == 10)
        #expect(configuration.backoffInterval(consecutiveFailures: 2) == 20)
        #expect(configuration.backoffInterval(consecutiveFailures: 3) == 25)
    }

    /// The defaults match the SDK this package replaces, so the swap does not
    /// silently change how often an install phones home.
    @Test("The shipped defaults are the ones the swap promised")
    func shippedDefaultsAreUnchanged() {
        let configuration = AethergramConfiguration(logSubsystem: testLogSubsystem)
        #expect(configuration.signalPrefix.isEmpty)
        #expect(configuration.batchSize == 100)
        #expect(configuration.queueLimit == 1000)
        #expect(configuration.transmitInterval == 10)
        #expect(configuration.maxBackoffInterval == 300)
    }

    /// The coalescing policy, asserted without scheduling anything.
    ///
    /// The regression the delivery work exists to prevent was not a wrong
    /// delay, it was no scheduling call at all — ten signals sat queued through
    /// two minutes of active use. This pins the decision; the integration
    /// tests in `DeliverySchedulingTests` pin that the decision is acted on.
    @Test("Delivery waits out the interval until the batch is full")
    func deliveryDelayCoalescesUntilTheBatchIsFull() {
        let configuration = AethergramConfiguration(
            logSubsystem: testLogSubsystem,
            batchSize: 3,
            transmitInterval: 10
        )
        #expect(configuration.deliveryDelay(queued: 1) == 10)
        #expect(configuration.deliveryDelay(queued: 2) == 10)
        #expect(configuration.deliveryDelay(queued: 3) == 0)
        #expect(configuration.deliveryDelay(queued: 4) == 0)
    }

    /// A batch size of one is the degenerate case a consumer can configure, and
    /// it has to mean "send every signal now" rather than "wait forever".
    @Test("A batch size of one never coalesces")
    func batchSizeOneAlwaysSendsNow() {
        let configuration = AethergramConfiguration(
            logSubsystem: testLogSubsystem,
            batchSize: 1,
            transmitInterval: 3600
        )
        #expect(configuration.deliveryDelay(queued: 1) == 0)
    }
}

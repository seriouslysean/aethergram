@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// The retry schedule is a pure function precisely so it can be asserted
/// without waiting for it.
@Suite("Transmission backoff", .tags(.lifecycle))
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

    /// A cap below the steady interval means no growth, not a retry faster
    /// than the interval it is meant to back off from — `batchSizeOneAlwaysSendsNow`
    /// below is exactly this shape (a raised transmitInterval, the default cap)
    /// and is a valid configuration, not one that should trap.
    @Test("A maxBackoffInterval below transmitInterval floors at transmitInterval, not the cap")
    func maxBackoffIntervalBelowTransmitIntervalFloorsAtTransmitInterval() {
        let configuration = testConfiguration(transmitInterval: 10, maxBackoffInterval: 5)
        #expect(configuration.backoffInterval(consecutiveFailures: 1) == 10)
    }

    /// Every install that failed together retries together on a fixed
    /// schedule, so an outage that ends is met by all of them in the same
    /// second. The jittered draw has to spread them.
    @Test("Jittered backoff spreads retries rather than landing every install on the ceiling")
    func jitteredBackoffSpreadsRetries() {
        let configuration = AethergramConfiguration(logSubsystem: testLogSubsystem)
        var generator = SeededGenerator(seed: 1)
        let draws = (0 ..< 64).map { _ in
            configuration.backoffInterval(consecutiveFailures: 3, using: &generator)
        }
        #expect(Set(draws).count > 32)
    }

    /// The draw stays inside `[max(transmitInterval, ceiling / 2), ceiling]`:
    /// never faster than the steady state the schedule backs off from, never
    /// slower than the ceiling. The second configuration puts the cap below
    /// twice the interval, where half the ceiling alone would undercut it.
    @Test(
        "Jittered backoff never retries faster than the steady interval or slower than the ceiling",
        arguments: [(10.0, 300.0), (10.0, 15.0), (10.0, 5.0)]
    )
    func jitteredBackoffStaysInsideTheSchedule(transmitInterval: TimeInterval, maxBackoffInterval: TimeInterval) {
        let configuration = testConfiguration(
            transmitInterval: transmitInterval,
            maxBackoffInterval: maxBackoffInterval
        )
        var generator = SeededGenerator(seed: 7)
        for failures in 1 ... 12 {
            let ceiling = configuration.backoffInterval(consecutiveFailures: failures)
            let floor = max(configuration.transmitInterval, ceiling / 2)
            for _ in 0 ..< 32 {
                let draw = configuration.backoffInterval(consecutiveFailures: failures, using: &generator)
                #expect(draw >= floor && draw <= ceiling, "failures=\(failures) draw=\(draw)")
            }
        }
    }

    /// Jitter belongs to a retry. The steady interval is the coalescing
    /// window, and moving it would change how often a healthy install sends.
    @Test("With no failure the jittered draw is the steady interval exactly")
    func jitteredBackoffLeavesTheSteadyIntervalAlone() {
        let configuration = AethergramConfiguration(logSubsystem: testLogSubsystem)
        var generator = SeededGenerator(seed: 3)
        #expect(configuration.backoffInterval(consecutiveFailures: 0, using: &generator) == 10)
        #expect(configuration.backoffInterval(consecutiveFailures: -1, using: &generator) == 10)
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

/// SplitMix64, so a jittered draw is repeatable in a test without reaching
/// for the system generator.
private struct SeededGenerator: RandomNumberGenerator {
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private var state: UInt64
}

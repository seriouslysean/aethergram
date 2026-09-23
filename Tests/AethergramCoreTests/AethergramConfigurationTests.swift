@testable import AethergramCore
import AethergramTestSupport
import Foundation
import Testing

/// `batchSize`/`queueLimit` are caller configuration, not a runtime
/// condition to recover from: a zero batchSize sends empty batches forever
/// (`nextBatch`'s `prefix(batchSize)` is always empty) and a negative
/// queueLimit traps `enqueue`'s overflow eviction
/// (`removeFirst(pending.count - queueLimit)` requests more elements than
/// the array holds). Both fail at construction instead.
///
/// Serialized: each trapping test re-execs the whole test binary, and fifteen of
/// them racing the async suites elsewhere in the target crashes the runner
/// before any test reports — a gate that cannot run looks exactly like one
/// that passed.
@Suite("AethergramConfiguration", .serialized, .tags(.lifecycle))
struct AethergramConfigurationTests {
    /// The ceilings are inclusive: a host that sets exactly one year or
    /// exactly 1,250 keeps its value rather than trapping at the boundary.
    @Test("An interval of exactly one year and a queueLimit of exactly 1,250 construct and keep their values")
    func valuesAtTheCeilingConstruct() {
        let oneYear: TimeInterval = 365 * 24 * 60 * 60
        let configuration = AethergramConfiguration(
            logSubsystem: "test",
            queueLimit: 1250,
            transmitInterval: oneYear,
            maxBackoffInterval: oneYear
        )
        #expect(configuration.queueLimit == 1250)
        #expect(configuration.transmitInterval == oneYear)
        #expect(configuration.maxBackoffInterval == oneYear)
    }

    /// A sleep that runs traps on a duration past `Int64.max` seconds, about
    /// 9.2e18, and `Duration.seconds` itself past about 1.7e20. The largest
    /// interval that constructs must sit below both, and the `#require` is
    /// the only guard for the running sleep: the cancelled sleep below never
    /// runs, so it proves the conversion to a `Duration` and nothing more.
    @Test("The largest interval that constructs converts to a Duration without trapping")
    func largestIntervalConvertsToADuration() async throws {
        try #require(AethergramConfiguration.maximumInterval < Double(Int64.max))
        let configuration = AethergramConfiguration(
            logSubsystem: "test",
            transmitInterval: AethergramConfiguration.maximumInterval,
            maxBackoffInterval: AethergramConfiguration.maximumInterval
        )
        let delay = configuration.deliveryDelay(queued: 1)
        let backoff = configuration.backoffInterval(consecutiveFailures: 64)

        #expect(backoff == AethergramConfiguration.maximumInterval)
        let sleep = Task { try await Task.sleep(for: .seconds(delay)) }
        sleep.cancel()
        _ = await sleep.result
        let now = ContinuousClock.now
        #expect(now.advanced(by: .seconds(backoff)) > now)
    }

    /// Restore decodes the whole queue file at consent grant on the caller's
    /// thread, so a queue past 1,250 signals is a grant that blocks past the
    /// budget; 0.3.x accepted any positive value and let the host find that
    /// out on a device.
    @Test("A queueLimit past 1,250 traps at construction")
    func queueLimitPastTheCeilingTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AethergramConfiguration(logSubsystem: "test", queueLimit: 1251)
        }
    }

    /// 0.3.2 clamped an interval only past about 1e15 seconds, so a typo of a
    /// few orders of magnitude constructed and silently never delivered.
    @Test("An interval past one year traps at construction", arguments: [
        InvalidInterval(property: .transmitInterval, value: .pastOneYear),
        InvalidInterval(property: .maxBackoffInterval, value: .pastOneYear),
        InvalidInterval(property: .transmitInterval, value: .huge),
        InvalidInterval(property: .maxBackoffInterval, value: .huge)
    ])
    private func intervalPastTheCeilingTraps(_ invalid: InvalidInterval) async {
        await #expect(processExitsWith: .failure) { [invalid] in
            switch invalid.property {
            case .transmitInterval:
                _ = AethergramConfiguration(logSubsystem: "test", transmitInterval: invalid.value.interval)
            case .maxBackoffInterval:
                _ = AethergramConfiguration(logSubsystem: "test", maxBackoffInterval: invalid.value.interval)
            }
        }
    }

    @Test("Positive batchSize and queueLimit construct without trapping")
    func validValuesConstruct() {
        let configuration = AethergramConfiguration(logSubsystem: "test", batchSize: 1, queueLimit: 1)
        #expect(configuration.batchSize == 1)
        #expect(configuration.queueLimit == 1)
    }

    @Test("A zero batchSize traps at construction")
    func zeroBatchSizeTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AethergramConfiguration(logSubsystem: "test", batchSize: 0)
        }
    }

    @Test("A negative queueLimit traps at construction")
    func negativeQueueLimitTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AethergramConfiguration(logSubsystem: "test", queueLimit: -1)
        }
    }

    /// One invalid value for one interval property. `Codable & Sendable` so
    /// the exit-test closure below can capture it across the re-exec into the
    /// child process. `Value` carries the category rather than the `Double`
    /// itself: the capture is serialized as JSON, which cannot represent NaN
    /// or infinity, so the actual non-finite value is reconstructed in the
    /// child process instead of transported into it.
    private struct InvalidInterval: Codable, Sendable, CustomStringConvertible {
        enum Property: String, Codable, Sendable {
            case transmitInterval
            case maxBackoffInterval
        }

        enum Value: String, Codable, Sendable {
            case zero
            case negative
            case nan
            case infinite
            case pastOneYear
            case huge

            var interval: TimeInterval {
                switch self {
                case .zero: 0
                case .negative: -1
                case .nan: .nan
                case .infinite: .infinity
                case .pastOneYear: 365 * 24 * 60 * 60 + 1
                case .huge: 1e21
                }
            }
        }

        let property: Property
        let value: Value

        var description: String { "\(property) = \(value)" }
    }

    /// A non-positive or NaN transmitInterval reaches the recorder as a retry
    /// delay that is not greater than zero and hot-loops; an infinite one never
    /// delivers. The same values on maxBackoffInterval are a contradiction of
    /// the floor `backoffInterval` applies, or the loss of its cap.
    @Test(
        "A non-finite or non-positive interval traps at construction",
        arguments: [
            InvalidInterval(property: .transmitInterval, value: .zero),
            InvalidInterval(property: .transmitInterval, value: .negative),
            InvalidInterval(property: .transmitInterval, value: .nan),
            InvalidInterval(property: .transmitInterval, value: .infinite),
            InvalidInterval(property: .maxBackoffInterval, value: .zero),
            InvalidInterval(property: .maxBackoffInterval, value: .negative),
            InvalidInterval(property: .maxBackoffInterval, value: .nan),
            InvalidInterval(property: .maxBackoffInterval, value: .infinite)
        ]
    )
    private func invalidIntervalTraps(_ invalid: InvalidInterval) async {
        await #expect(processExitsWith: .failure) { [invalid] in
            switch invalid.property {
            case .transmitInterval:
                _ = AethergramConfiguration(logSubsystem: "test", transmitInterval: invalid.value.interval)
            case .maxBackoffInterval:
                _ = AethergramConfiguration(logSubsystem: "test", maxBackoffInterval: invalid.value.interval)
            }
        }
    }
}

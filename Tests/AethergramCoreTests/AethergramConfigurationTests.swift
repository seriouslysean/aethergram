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
/// Serialized: each trapping test re-execs the whole test binary, and ten of
/// them racing the async suites elsewhere in the target crashes the runner
/// before any test reports — a gate that cannot run looks exactly like one
/// that passed.
@Suite("AethergramConfiguration", .serialized)
struct AethergramConfigurationTests {
    /// Pinned as literals rather than read off the type: a ceiling that moved
    /// would change which host configurations launch, and that must fail here.
    static let intervalCeiling: TimeInterval = 365 * 24 * 60 * 60
    static let queueLimitCeiling = 100_000

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

    @Test("A queueLimit past its ceiling traps at construction")
    func queueLimitPastCeilingTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AethergramConfiguration(
                logSubsystem: "test",
                queueLimit: Self.queueLimitCeiling + 1
            )
        }
    }

    /// The ceilings are inclusive: a host configured exactly at one keeps
    /// launching.
    @Test("Every value at its ceiling constructs without trapping")
    func valuesAtCeilingConstruct() {
        let configuration = AethergramConfiguration(
            logSubsystem: "test",
            queueLimit: Self.queueLimitCeiling,
            transmitInterval: Self.intervalCeiling,
            maxBackoffInterval: Self.intervalCeiling
        )
        #expect(configuration.queueLimit == Self.queueLimitCeiling)
        #expect(configuration.backoffInterval(consecutiveFailures: 64) == Self.intervalCeiling)
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
            case overAYear

            var interval: TimeInterval {
                switch self {
                case .zero: 0
                case .negative: -1
                case .nan: .nan
                case .infinite: .infinity
                case .overAYear: AethergramConfigurationTests.intervalCeiling.nextUp
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
    /// the floor `backoffInterval` applies, or the loss of its cap. A finite
    /// value past a year is no schedule anyone means, and past about 1.7e20 it
    /// traps `Duration.seconds` at the first retry instead of here.
    @Test(
        "A non-finite, non-positive, or over-a-year interval traps at construction",
        arguments: [
            InvalidInterval(property: .transmitInterval, value: .zero),
            InvalidInterval(property: .transmitInterval, value: .negative),
            InvalidInterval(property: .transmitInterval, value: .nan),
            InvalidInterval(property: .transmitInterval, value: .infinite),
            InvalidInterval(property: .transmitInterval, value: .overAYear),
            InvalidInterval(property: .maxBackoffInterval, value: .zero),
            InvalidInterval(property: .maxBackoffInterval, value: .negative),
            InvalidInterval(property: .maxBackoffInterval, value: .nan),
            InvalidInterval(property: .maxBackoffInterval, value: .infinite),
            InvalidInterval(property: .maxBackoffInterval, value: .overAYear)
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

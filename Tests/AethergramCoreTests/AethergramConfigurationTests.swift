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
@Suite("AethergramConfiguration", .serialized, .tags(.lifecycle))
struct AethergramConfigurationTests {
    /// A patch release keeps every configuration that ran under the last one
    /// running: a long interval or a large queue is the host's policy to set.
    @Test("A two-year interval and a queueLimit of 200,000 construct and keep their values")
    func largeValuesThatRanBeforeStillConstruct() {
        let twoYears: TimeInterval = 2 * 365 * 24 * 60 * 60
        let configuration = AethergramConfiguration(
            logSubsystem: "test",
            queueLimit: 200_000,
            transmitInterval: twoYears,
            maxBackoffInterval: twoYears
        )
        #expect(configuration.queueLimit == 200_000)
        #expect(configuration.transmitInterval == twoYears)
        #expect(configuration.maxBackoffInterval == twoYears)
    }

    /// A sleep that runs traps on a duration past `Int64.max` seconds, about
    /// 9.2e18, and `Duration.seconds` itself past about 1.7e20, so under 0.3.1
    /// an interval that large constructed and then crashed its host at the
    /// first sleep that ran on it. The `#require` is the guard for the running
    /// sleep: a ceiling raised past `Int64.max` fails there rather than
    /// trapping the runner. The cancelled sleep and the retry deadline below
    /// are built from the clamped values, which covers only the conversion to
    /// a `Duration`.
    @Test("An interval too large for a Duration is clamped rather than trapping the first record's sleep")
    func intervalTooLargeForADurationIsClamped() async throws {
        try #require(AethergramConfiguration.maximumInterval < Double(Int64.max))
        let configuration = AethergramConfiguration(
            logSubsystem: "test",
            transmitInterval: 1e21,
            maxBackoffInterval: 1e21
        )
        let delay = configuration.deliveryDelay(queued: 1)
        let backoff = configuration.backoffInterval(consecutiveFailures: 64)

        #expect(configuration.transmitInterval <= AethergramConfiguration.maximumInterval)
        #expect(configuration.maxBackoffInterval <= AethergramConfiguration.maximumInterval)
        #expect(backoff <= AethergramConfiguration.maximumInterval)
        // Cancelled at once, so nothing waits out the interval and the sleep
        // never runs: `.seconds` converts it before the sleep looks at
        // cancellation, which proves the conversion and nothing about the
        // running sleep's limit.
        let sleep = Task { try await Task.sleep(for: .seconds(delay)) }
        sleep.cancel()
        _ = await sleep.result
        let now = ContinuousClock.now
        #expect(now.advanced(by: .seconds(backoff)) > now)
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

            var interval: TimeInterval {
                switch self {
                case .zero: 0
                case .negative: -1
                case .nan: .nan
                case .infinite: .infinity
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

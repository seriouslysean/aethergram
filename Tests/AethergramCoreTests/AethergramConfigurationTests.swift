@testable import AethergramCore
import AethergramTestSupport
import Testing

/// `batchSize`/`queueLimit` are caller configuration, not a runtime
/// condition to recover from: a zero batchSize sends empty batches forever
/// (`nextBatch`'s `prefix(batchSize)` is always empty) and a negative
/// queueLimit traps `enqueue`'s overflow eviction
/// (`removeFirst(pending.count - queueLimit)` requests more elements than
/// the array holds). Both fail at construction instead.
@Suite("AethergramConfiguration")
struct AethergramConfigurationTests {
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
}

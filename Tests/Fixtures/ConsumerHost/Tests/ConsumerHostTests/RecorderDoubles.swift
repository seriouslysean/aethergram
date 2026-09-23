import Aethergram
import Dispatch
import Foundation
import Synchronization

// Doubles written against the public API alone, as a host would write them: the core's own test
// doubles are internal to it.

/// A transport whose send parks until released, honouring cancellation as the protocol asks.
final class HeldTransport: SignalTransport {
    let entered = Flag()
    private let released = Flag()

    func release() { released.set() }

    func send(_ batch: SignalBatch) async -> TransportOutcome {
        entered.set()
        await withTaskCancellationHandler {
            await released.wait()
        } onCancel: {
            released.set()
        }
        return Task.isCancelled ? .retryable(reason: "cancelled") : .delivered
    }
}

/// A transport that accepts every batch at once.
struct AcceptingTransport: SignalTransport {
    func send(_ batch: SignalBatch) async -> TransportOutcome { .delivered }
}

/// A queue store in memory whose `persist` parks the writer's thread once held, until released.
final class HeldStore: SignalQueueStorage {
    let persistEntered = Flag()
    private let state = Mutex<(held: Bool, signals: [Signal])>((false, []))
    private let gate = DispatchSemaphore(value: 0)

    func hold() { state.withLock { $0.held = true } }

    func release() {
        state.withLock { $0.held = false }
        gate.signal()
    }

    func load() -> [Signal] { state.withLock { $0.signals } }

    func persist(_ signals: [Signal]) {
        if state.withLock({ $0.held }) {
            persistEntered.set()
            // Bounded, so a test that forgets to release cannot hold the writer for the process.
            _ = gate.wait(timeout: .now() + 30)
            gate.signal()
        }
        state.withLock { $0.signals = signals }
    }

    func purge() { state.withLock { $0.signals = [] } }
}

/// Retention in memory.
final class MemoryRetention: RetentionStore {
    private let record = Mutex<RetentionRecord?>(nil)
    func load() -> RetentionRecord? { record.withLock { $0 } }
    func save(_ record: RetentionRecord) { self.record.withLock { $0 = record } }
    func clear() { record.withLock { $0 = nil } }
}

/// A granted recorder holding one recorded signal.
func grantedRecorder(transport: any SignalTransport, store: any SignalQueueStorage) -> SignalRecorder {
    let recorder = SignalRecorder(
        configuration: AethergramConfiguration(logSubsystem: "fixture"),
        transport: transport,
        queueStorage: store,
        retentionStore: MemoryRetention(),
        clientUserProvider: { "host-user" },
        environmentProvider: { [:] }
    )
    recorder.updateConsent(.granted)
    recorder.record("fixture.flushed")
    return recorder
}

/// Sets a flag once `body` returns, so a test bounds an await it cannot otherwise time out.
func finishes(_ body: @escaping @Sendable () async -> Void) -> Flag {
    let done = Flag()
    Task.detached {
        await body()
        done.set()
    }
    return done
}

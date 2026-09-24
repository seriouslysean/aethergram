// What a host writes against the package, compiled as a host compiles it: through `import
// Aethergram` alone, in a module with no upcoming-feature flag. Nothing calls these; a change to
// the package that stops any of them compiling is one a host would meet on upgrade.
import Aethergram

/// A switch over `TransportOutcome` with `default:`, which is what the enum's stability contract
/// asks of a host, so a new case compiles.
func describe(_ outcome: TransportOutcome) -> String {
    switch outcome {
    case .delivered:
        "delivered"
    case .retryable(let reason), .permanent(let reason):
        reason
    default:
        "other"
    }
}

/// A host's own transport, witnessing the `nonisolated(nonsending)` requirement with a plain
/// async method in a module where that is not the default.
struct HostTransport: SignalTransport {
    func send(_ batch: SignalBatch) async -> TransportOutcome {
        batch.signals.isEmpty ? .permanent(reason: "empty") : .delivered
    }
}

/// The 0.3.x name, deprecated in 0.4.0: it must still compile, with a warning.
func legacyTestPartition(_ snapshot: EnvironmentSnapshot) -> Bool {
    TelemetryDeckConfiguration.testPartition(for: snapshot)
}

/// The two calls a host's lifecycle makes: an awaited flush on the way out, and a data reset that
/// replaces the identifier with collection closed.
func onResign(_ recorder: SignalRecorder) async {
    recorder.endSession()
    await recorder.flushAndWait()
}

func onDataReset(_ recorder: SignalRecorder, rotateIdentifier: () throws -> Void) rethrows {
    try recorder.resetClosingCollection(during: rotateIdentifier)
}

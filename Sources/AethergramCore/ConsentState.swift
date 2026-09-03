import Foundation

/// Whether the person has authorized collection.
///
/// `neverAsked` is not a decline. Both states forbid collection, which is why
/// `permitsCollection` collapses them, but only `neverAsked` still owes the
/// user an ask — the consumer's gate screen reads the distinction, the
/// recorder reads the verdict.
///
/// The package treats a non-granted state as an absolute bar, not a filter:
/// nothing is enqueued, nothing is written to disk, no identifier is resolved,
/// and no counter advances until the answer is `granted`. That is the core's
/// one non-negotiable requirement, and `ConsentEnforcementTests` is its proof.
public enum ConsentState: String, Equatable, Sendable {
    case neverAsked
    case granted
    case declined

    /// The only question the recorder asks. Everything else about the answer —
    /// how it was captured, where it is stored, whether it syncs across the
    /// person's devices — is the consumer's, because storage and sync
    /// assumptions are host-specific.
    public var permitsCollection: Bool {
        self == .granted
    }
}

import Foundation

/// A batch of signals handed to a transport, plus the two per-batch fields
/// every ingest API this package targets requires.
public struct SignalBatch: Equatable, Sendable {
    // MARK: Lifecycle

    public init(signals: [Signal], clientUser: String, sessionID: String) {
        self.signals = signals
        self.clientUser = clientUser
        self.sessionID = sessionID
    }

    // MARK: Public

    public let signals: [Signal]

    /// The consumer's own analytics identifier, unhashed. An adapter that
    /// needs it hashed hashes it; the core never invents an identifier and
    /// never persists one.
    public let clientUser: String

    /// Stable for the length of one consumer-defined session.
    public let sessionID: String
}

/// What the core does next with a batch it just handed over.
///
/// The distinction that matters is `retryable` versus `permanent`: a permanent
/// rejection must not be retried forever against an endpoint that will keep
/// rejecting it, and an adapter is the only layer that can tell the two apart.
public enum TransportOutcome: Equatable, Sendable {
    /// Accepted. The batch leaves the queue.
    case delivered
    /// Try the same batch again after a backoff. It stays queued.
    case retryable(reason: String)
    /// Rejected in a way retrying cannot fix. The batch is dropped.
    case permanent(reason: String)
}

/// The seam that keeps the core vendor-free.
///
/// Deliberately small: an adapter accepts a batch that is already built, and
/// decides nothing about when to send, what to retry, or whether consent
/// exists. It owns exactly one thing — the wire — and holds no storage of its
/// own, so nothing an adapter writes survives it.
///
/// The review question for any second adapter: could it be written against
/// this protocol without changing a line of `AethergramCore`?
public protocol SignalTransport: Sendable {
    func send(_ batch: SignalBatch) async -> TransportOutcome
}

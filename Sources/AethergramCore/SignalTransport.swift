import Foundation

/// A batch of signals handed to a transport, plus the one field every ingest
/// API this package targets takes per batch rather than per signal.
public struct SignalBatch: Equatable, Sendable {
    // MARK: Lifecycle

    public init(signals: [Signal], clientUser: String) {
        self.signals = signals
        self.clientUser = clientUser
    }

    // MARK: Public

    /// The signals to send, oldest first. The recorder hands over at most
    /// `AethergramConfiguration.batchSize`.
    public let signals: [Signal]

    /// The consumer's own analytics identifier, unhashed. `clientUser` is the
    /// package's neutral name for the identifier a backend groups signals
    /// by, resolved by the host's `clientUserProvider`. An adapter that
    /// needs it hashed hashes it; the core never invents an identifier and
    /// never persists one.
    public let clientUser: String
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
    /// Try the same batch again no sooner than `delay` seconds from now, as
    /// the backend asked. It stays queued, and counts as a failure exactly as
    /// `retryable` does; the recorder waits for the later of `delay` and its
    /// own backoff, and bounds `delay` at the one-year interval ceiling.
    ///
    /// A separate case rather than a second value on `retryable`, because a
    /// host that binds `case let .retryable(reason)` would stop compiling on
    /// that; a new case breaks only a switch with no `default`, which this
    /// enum's stability contract already requires. A host that matches
    /// `.retryable` alone to mean "will be retried" must match this case too.
    case retryableAfter(reason: String, delay: TimeInterval)
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
///
/// A conformance must honour task cancellation: the recorder cancels a send
/// in flight when consent is withdrawn or the host resets, and a send that
/// ignores it runs to completion with the batch it was handed. Sends may
/// overlap across an erase — the cancelled send can still be in flight when
/// the drain after the erase sends a different batch — so a conformance must
/// not assume one send at a time.
public protocol SignalTransport: Sendable {
    /// Sends one batch and reports what the recorder should do with it.
    /// Called from the recorder's drain task, never under its lock.
    ///
    /// Spelled `nonisolated(nonsending)` (SE-0461) rather than left to the
    /// module's upcoming-feature flag, so the requirement means the same thing
    /// whatever flags this module is built with. A witness may still be
    /// plain, `@concurrent`, or actor-isolated.
    nonisolated(nonsending) func send(_ batch: SignalBatch) async -> TransportOutcome
}

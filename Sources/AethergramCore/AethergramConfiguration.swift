import Foundation

/// Queue and transmission policy. Everything a vendor owns — endpoint,
/// namespace, app identifier, salt — lives on the adapter instead, so this type
/// stays true wherever the signals end up.
public struct AethergramConfiguration: Sendable {
    // MARK: Lifecycle

    /// Defaults match the SDK this package replaces, so the swap does not
    /// silently change how often an install phones home: batch on a 10s
    /// interval, back off to at most 5 minutes.
    ///
    /// - Precondition: `batchSize` is positive; `queueLimit` is positive and at
    ///   most 100,000; `transmitInterval` and `maxBackoffInterval` are finite,
    ///   positive, and at most one year. Anything else traps here, at
    ///   construction, rather than at the first signal.
    public init(
        signalPrefix: String = "",
        logSubsystem: String,
        batchSize: Int = 100,
        queueLimit: Int = 1000,
        transmitInterval: TimeInterval = 10,
        maxBackoffInterval: TimeInterval = 300
    ) {
        // batchSize == 0 makes nextBatch's `prefix(batchSize)` always empty,
        // so the transport sends empty batches forever without ever draining
        // the queue. A negative queueLimit makes enqueue's overflow eviction
        // (`removeFirst(pending.count - queueLimit)`) request more elements
        // than the array holds and trap. A zero, negative, or NaN
        // transmitInterval reaches the recorder as a retry delay that is not
        // greater than zero, retrying a retryable failure immediately in a hot
        // loop, and an infinite one never delivers. maxBackoffInterval is
        // floored at transmitInterval by `backoffInterval`, so a non-positive
        // value there is only a contradiction and an infinite one removes the
        // cap. A finite interval past about 1.7e20 seconds traps
        // `Duration.seconds` at the first retry, so the ceiling sits far below
        // that. All of these are caller configuration errors, not a runtime
        // condition to recover from.
        precondition(batchSize > 0, "AethergramConfiguration.batchSize must be positive")
        precondition(
            queueLimit > 0 && queueLimit <= Self.maximumQueueLimit,
            "AethergramConfiguration.queueLimit must be positive and at most \(Self.maximumQueueLimit)"
        )
        precondition(
            transmitInterval.isFinite && transmitInterval > 0 && transmitInterval <= Self.maximumInterval,
            "AethergramConfiguration.transmitInterval must be positive and at most one year"
        )
        precondition(
            maxBackoffInterval.isFinite && maxBackoffInterval > 0 && maxBackoffInterval <= Self.maximumInterval,
            "AethergramConfiguration.maxBackoffInterval must be positive and at most one year"
        )
        self.signalPrefix = signalPrefix
        self.logSubsystem = logSubsystem
        self.batchSize = batchSize
        self.queueLimit = queueLimit
        self.transmitInterval = transmitInterval
        self.maxBackoffInterval = maxBackoffInterval
    }

    // MARK: Public

    /// Prepended to consumer signal names so one dashboard can hold several
    /// surfaces. Presets bypass it: their names are the package's, not the
    /// consumer's, and a prefixed preset would not join with anything.
    public let signalPrefix: String

    /// The host's logging subsystem. A package that invented its own would log
    /// under a name that means nothing in the app being debugged.
    public let logSubsystem: String

    /// Signals per POST.
    public let batchSize: Int

    /// Hard cap on the durable queue. An extension that cannot reach the
    /// network for a week must not grow a file without bound; past the cap the
    /// oldest signals are dropped, because the recent ones describe the version
    /// someone is actually running.
    public let queueLimit: Int

    /// Delay between transmission attempts in the steady state.
    public let transmitInterval: TimeInterval

    /// Ceiling on the exponential backoff after repeated failures. A value
    /// below `transmitInterval` means no growth rather than a retry faster
    /// than the steady state it is meant to back off from.
    public let maxBackoffInterval: TimeInterval

    /// How long delivery waits after a signal is recorded: nothing once the
    /// batch is full, the coalescing interval otherwise.
    ///
    /// Pure and separate from the recorder so the policy is assertable without
    /// scheduling anything. The regression this exists to prevent was not a
    /// wrong delay — it was no scheduling call at all, so a burst of signals
    /// queued and waited for a resign event that an app extension barely gets.
    public func deliveryDelay(queued: Int) -> TimeInterval {
        queued >= batchSize ? 0 : transmitInterval
    }

    /// `transmitInterval * 2^failures`, capped. Pure so the schedule is
    /// testable without waiting for it.
    public func backoffInterval(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else { return transmitInterval }
        let scaled = transmitInterval * pow(2, Double(consecutiveFailures))
        return min(scaled, max(maxBackoffInterval, transmitInterval))
    }

    // MARK: Internal

    /// Ceiling on both intervals. A year is far past any real delivery
    /// schedule, so a larger value is a unit mistake rather than a policy.
    static let maximumInterval: TimeInterval = 365 * 24 * 60 * 60

    /// Ceiling on `queueLimit`: a hundred times the default. The queue is held
    /// in memory and rewritten whole on every save, so its limit is also the
    /// size of every write, and an extension's memory budget is small.
    static let maximumQueueLimit = 100_000
}

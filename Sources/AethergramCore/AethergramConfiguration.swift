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
    /// - Precondition: `batchSize` and `queueLimit` are positive;
    ///   `transmitInterval` and `maxBackoffInterval` are finite and positive.
    ///   Anything else traps here, at construction, rather than at the first
    ///   signal. Both intervals are clamped to a ceiling far past any real
    ///   schedule and below the size that would crash the first retry.
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
        // cap. All four are caller configuration errors, not a runtime
        // condition to recover from; fail at construction, not at the first
        // signal.
        precondition(batchSize > 0, "AethergramConfiguration.batchSize must be positive")
        precondition(queueLimit > 0, "AethergramConfiguration.queueLimit must be positive")
        precondition(
            transmitInterval.isFinite && transmitInterval > 0,
            "AethergramConfiguration.transmitInterval must be finite and positive"
        )
        precondition(
            maxBackoffInterval.isFinite && maxBackoffInterval > 0,
            "AethergramConfiguration.maxBackoffInterval must be finite and positive"
        )
        self.signalPrefix = signalPrefix
        self.logSubsystem = logSubsystem
        self.batchSize = batchSize
        self.queueLimit = queueLimit
        // Clamped rather than trapped: every value that constructed before
        // still constructs, and the ones that crashed at the first retry now
        // run.
        self.transmitInterval = min(transmitInterval, Self.maximumInterval)
        self.maxBackoffInterval = min(maxBackoffInterval, Self.maximumInterval)
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

    /// What both intervals are clamped to. Not a policy ceiling: `Duration`
    /// traps on seconds past about 1.7e20, which is where a retry deadline
    /// built from a larger interval crashed, and this sits five orders of
    /// magnitude below that and some thirty million years past any schedule.
    static let maximumInterval: TimeInterval = 1e15

    /// `queueLimit`'s default, and the bound on what a queue store carries
    /// for the next process, which has no configuration to read. Read off the
    /// initializer rather than named in it, so the two cannot drift and the
    /// public signature shows a value rather than an internal name.
    static let defaultQueueLimit = AethergramConfiguration(logSubsystem: "").queueLimit
}

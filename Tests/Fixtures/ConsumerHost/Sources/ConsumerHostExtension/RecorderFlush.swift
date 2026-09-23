import Aethergram

// The work a host runs under either pattern: one awaited flush, which returns promptly once the
// expiry cancels it, whether the transport or the queue store is still holding it.

extension ExpiringFlush {
    /// A flush of `recorder` inside one grant of background time.
    public convenience init(
        begin: @escaping @Sendable () -> Void = {},
        expire: @escaping @Sendable () -> Void = {},
        end: @escaping @Sendable () -> Void,
        recorder: SignalRecorder
    ) {
        self.init(begin: begin, expire: expire, end: end, work: { await recorder.flushAndWait() })
    }
}

extension ExtensionFlush {
    /// Flushes `recorder` inside an expiring activity.
    public static func run(
        reason: String,
        performExpiringActivity: PerformExpiringActivity,
        begin: @escaping @Sendable () -> Void = {},
        expire: @escaping @Sendable () -> Void = {},
        recorder: SignalRecorder
    ) {
        run(
            reason: reason, performExpiringActivity: performExpiringActivity,
            begin: begin, expire: expire, work: { await recorder.flushAndWait() }
        )
    }
}

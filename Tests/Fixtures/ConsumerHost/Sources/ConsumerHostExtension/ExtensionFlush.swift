import Foundation

/// The extension pattern: work run under `ProcessInfo.performExpiringActivity(withReason:using:)`.
///
/// That call runs its block on a background queue, and the activity lasts until the block
/// returns. The block may first be called with `expired == true`, when no time can be granted, and
/// is called again with `expired == true`, concurrently, while the first call is still running.
public enum ExtensionFlush {
    /// `performExpiringActivity(withReason:using:)`, injected so a test can drive every ordering.
    public typealias PerformExpiringActivity =
        @Sendable (_ reason: String, _ block: @escaping @Sendable (_ expired: Bool) -> Void) -> Void

    #if !os(macOS)
    /// The system's call, which macOS does not have.
    public static let processInfo: PerformExpiringActivity = { reason, block in
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: block)
    }
    #endif

    /// Starts `work` inside an expiring activity and returns at once; the activity holds until
    /// the work finishes or the system expires it, and expiry cancels the work.
    public static func run(
        reason: String,
        performExpiringActivity: PerformExpiringActivity,
        begin: @escaping @Sendable () -> Void = {},
        expire: @escaping @Sendable () -> Void = {},
        work: @escaping ExpiringFlush.Work
    ) {
        run(
            reason: reason, performExpiringActivity: performExpiringActivity,
            begin: begin, expire: expire, work: work, beforeRegistration: {}
        )
    }

    static func run(
        reason: String,
        performExpiringActivity: PerformExpiringActivity,
        begin: @escaping @Sendable () -> Void,
        expire: @escaping @Sendable () -> Void,
        work: @escaping ExpiringFlush.Work,
        beforeRegistration: @escaping @Sendable () -> Void
    ) {
        let done = DispatchSemaphore(value: 0)
        let flush = ExpiringFlush(
            begin: begin, expire: expire, end: { done.signal() }, work: work,
            beforeRegistration: beforeRegistration
        )
        performExpiringActivity(reason) { expired in
            if expired {
                flush.expire()
            } else if flush.start(priority: .utility) {
                // Blocks this background queue's thread, never the cooperative pool the task
                // runs on. Returning ends the activity.
                done.wait()
            }
        }
    }
}

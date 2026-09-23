import Foundation
import Synchronization

/// One piece of work run inside a grant of background time the platform may revoke at any moment.
///
/// The work runs on a detached task. Revoking the grant cancels that task, whether it is already
/// registered or registers afterwards, so the work must honour cancellation. `end` is called
/// exactly once, by whichever of the work finishing and the grant expiring comes first.
public final class ExpiringFlush: Sendable {
    public typealias Work = @Sendable () async -> Void

    private struct State {
        var task: Task<Void, Never>?
        var expired = false
        var ended = false
    }

    private let state = Mutex(State())
    private let onBegin: @Sendable () -> Void
    private let onExpire: @Sendable () -> Void
    private let onEnd: @Sendable () -> Void
    private let work: Work
    /// Runs between the task's creation and its registration, so a test can land an expiry there.
    private let beforeRegistration: @Sendable () -> Void

    /// - Parameters:
    ///   - begin: called once the work is registered and the grant has not expired.
    ///   - expire: called once, on the first expiry.
    ///   - end: called exactly once, when the work finishes or the grant expires.
    ///   - work: the work; it must return promptly once cancelled.
    public convenience init(
        begin: @escaping @Sendable () -> Void = {},
        expire: @escaping @Sendable () -> Void = {},
        end: @escaping @Sendable () -> Void,
        work: @escaping Work
    ) {
        self.init(begin: begin, expire: expire, end: end, work: work, beforeRegistration: {})
    }

    init(
        begin: @escaping @Sendable () -> Void,
        expire: @escaping @Sendable () -> Void,
        end: @escaping @Sendable () -> Void,
        work: @escaping Work,
        beforeRegistration: @escaping @Sendable () -> Void
    ) {
        onBegin = begin
        onExpire = expire
        onEnd = end
        self.work = work
        self.beforeRegistration = beforeRegistration
    }

    /// Starts the work. Returns `false` when the grant expired first, and the caller must not wait:
    /// an expiry before the call starts nothing, and one that lands while the task is being
    /// created cancels it as it registers.
    @discardableResult
    public func start(priority: TaskPriority = .utility) -> Bool {
        let task = Task.detached(priority: priority) { [self] in
            await work()
            finish()
        }
        beforeRegistration()
        // Checked after the store, under the same lock `expire()` takes, so an expiry either sees
        // the task or leaves the flag this read sees.
        let expired = state.withLock { state in
            state.task = task
            return state.expired
        }
        if expired {
            task.cancel()
            return false
        }
        onBegin()
        return true
    }

    /// Revokes the grant: cancels the task if registered, or marks it to be cancelled as it
    /// registers, and ends the flush. Safe to call any number of times, from any thread.
    public func expire() {
        let (task, first) = state.withLock { state in
            defer { state.expired = true }
            return (state.task, !state.expired)
        }
        task?.cancel()
        if first { onExpire() }
        finish()
    }

    /// Waits for the work's task, if one was registered. For tests, which must not read the end
    /// count while a task could still call it.
    func waitForWork() async {
        await state.withLock { $0.task }?.value
    }

    private func finish() {
        let first = state.withLock { state in
            defer { state.ended = true }
            return !state.ended
        }
        if first { onEnd() }
    }
}

import Aethergram
import ConsumerHostExtension

/// The app pattern: work run under `UIApplication.beginBackgroundTask(withName:expirationHandler:)`.
///
/// `start` begins the background task, starts the work, and returns at once: the main actor never
/// waits on the work. Expiry cancels the work and ends the background task; `end()` hands the task
/// back exactly once, whichever of the work and the expiry gets there first.
///
/// The begin and end calls are injected, so this logic compiles and is tested where UIKit does not
/// exist; only the binding below is UIKit's.
@MainActor
public final class AppFlush<Token: Sendable> {
    public typealias BeginBackgroundTask =
        @MainActor (_ name: String, _ expirationHandler: @escaping @MainActor @Sendable () -> Void) -> Token
    public typealias EndBackgroundTask = @MainActor (Token) -> Void

    private let beginBackgroundTask: BeginBackgroundTask
    private let endBackgroundTask: EndBackgroundTask
    private let work: ExpiringFlush.Work
    private var token: Token?
    private var task: Task<Void, Never>?
    private var started = false
    private var expired = false
    private var ended = false

    public init(
        beginBackgroundTask: @escaping BeginBackgroundTask,
        endBackgroundTask: @escaping EndBackgroundTask,
        work: @escaping ExpiringFlush.Work
    ) {
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        self.work = work
    }

    /// Begins the background task and starts the work, without waiting for it. A second call
    /// does nothing.
    public func start(name: String) {
        guard !started else { return }
        started = true
        token = beginBackgroundTask(name) { [weak self] in self?.expire() }
        // An expiration handler run inside the begin call found no token to end with.
        if expired {
            end()
            return
        }
        task = Task { [work] in
            await work()
            self.end()
        }
    }

    /// Hands the background task back, once.
    public func end() {
        guard !ended, let token else { return }
        ended = true
        endBackgroundTask(token)
    }

    private func expire() {
        expired = true
        task?.cancel()
        end()
    }

    /// Waits for the work's task, if one started. For tests, which must not read the end count
    /// while the task could still call it.
    func waitForWork() async {
        await task?.value
    }
}

extension AppFlush {
    /// A flush of `recorder` inside one background task.
    public convenience init(
        beginBackgroundTask: @escaping BeginBackgroundTask,
        endBackgroundTask: @escaping EndBackgroundTask,
        recorder: SignalRecorder
    ) {
        self.init(
            beginBackgroundTask: beginBackgroundTask, endBackgroundTask: endBackgroundTask,
            work: { await recorder.flushAndWait() }
        )
    }
}

#if canImport(UIKit)
import UIKit

extension AppFlush where Token == UIBackgroundTaskIdentifier {
    /// Binds a flush of `recorder` to an application's background tasks.
    public convenience init(application: UIApplication, recorder: SignalRecorder) {
        self.init(
            beginBackgroundTask: { name, expirationHandler in
                application.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
            },
            endBackgroundTask: { application.endBackgroundTask($0) },
            recorder: recorder
        )
    }
}
#endif

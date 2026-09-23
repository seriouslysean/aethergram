import Foundation
import Synchronization

/// A one-shot flag an async test can wait on.
final class Flag: Sendable {
    private let state = Mutex<(set: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    var isSet: Bool { state.withLock { $0.set } }

    func set() {
        let waiters = state.withLock { state in
            defer { state = (true, []) }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state in
                if state.set { return true }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Whether the flag is set within `limit`, so a gate that never opens fails the test rather
    /// than hanging it.
    func within(_ limit: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !isSet {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// The stand-in for a flush: suspends until released or cancelled, and records which.
final class StubWork: Sendable {
    let started = Flag()
    let finished = Flag()
    private let released = Flag()
    private let cancelled = Mutex(false)

    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func release() { released.set() }

    func run() async {
        started.set()
        await withTaskCancellationHandler {
            await released.wait()
        } onCancel: {
            released.set()
        }
        cancelled.withLock { $0 = Task.isCancelled }
        finished.set()
    }
}

/// Counts calls from any thread.
final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

/// Runs a blocking call on a thread of its own, never the cooperative pool, and flags its return.
func onThread(_ body: @escaping @Sendable () -> Void) -> Flag {
    let returned = Flag()
    Thread.detachNewThread {
        body()
        returned.set()
    }
    return returned
}

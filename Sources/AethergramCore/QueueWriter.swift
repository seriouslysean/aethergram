import Foundation
import Synchronization

/// Serializes every write to the durable queue, in the order the recorder
/// committed them.
///
/// Two problems, one mechanism. Ordering: `record` can be called from the main
/// actor while a background diagnostic emit lands at the same moment, and two
/// unsynchronized `persist` calls can complete out of order — an older, shorter
/// snapshot overwriting a newer one, silently dropping a signal the queue
/// promises to keep. Cost: encoding and atomically rewriting the whole pending
/// set is O(queue) and was running on the caller's thread, up to
/// `queueLimit` entries, worst exactly when the device is offline and the queue
/// is longest.
///
/// The fix for both is to make the storage single-threaded and to take it off
/// the caller. Intent is captured under the recorder's own lock, so the order
/// of writes is the order of the mutations that produced them; the encode and
/// the write, the O(queue) work, happen on one serial queue. What stays on the
/// caller is a copy: a snapshot shares the pending array's storage, so the
/// next append or eviction while the writer still holds it copies the whole
/// queue under the lock.
///
/// **Coalescing is the point, not an optimization.** Only the newest snapshot
/// is ever written: a burst of ten records produces one file write, because
/// each snapshot supersedes the last. That is sound because a snapshot is the
/// whole queue rather than a delta — there is nothing in an older one that a
/// newer one lacks.
///
/// A purge is not superseded by anything. It drops every snapshot submitted
/// before it, so a stale one can never overtake it and resurrect what a decline
/// erased, and it stays pending under any snapshot submitted after it, because
/// a snapshot describes only what the recorder holds: a store can hold more
/// than that — a file it could not read, one it could not reach — and only
/// the erase says to drop it. The drain runs the purge, then the snapshot.
///
/// **The barrier.** Every submit takes a ticket, in submit order, and a wait
/// takes the newest at its call. A waiter returns once a write has landed
/// that covers every submission up to its ticket: the first drain step to
/// start after that submission has ended. Nothing submitted after the call
/// is promised by the return, even when it happens to be on the store by
/// then.
///
/// A later submission can still lengthen the wait, within that one step and
/// never by another. A step takes everything pending when it starts,
/// submissions made after the waiter included, and makes at most two store
/// calls: the purge, then the newest snapshot. A later snapshot that
/// supersedes a pending one, or a later purge that drops it, replaces that
/// call. The step makes one more call than the waiter's own submissions
/// needed only when it ends up holding a purge and a snapshot where those
/// held one of the two — a snapshot coalesced behind a pending purge is the
/// case the recorder meets. A submission made once the step has started
/// goes to the next step, which the waiter does not wait for.
///
/// **What this costs.** The write no longer completes before `record` returns,
/// so a kill in the microseconds between them loses that signal where the
/// synchronous version would not have. `flush()` closes that window at the one
/// moment it is known to matter, by waiting on the way out for the writes
/// submitted before it.
final class QueueWriter: Sendable {
    // MARK: Lifecycle

    init(storage: any SignalQueueStorage, label: String) {
        self.storage = storage
        queue = DispatchQueue(label: label, qos: .utility)
    }

    // MARK: Internal

    /// Records the intent to persist `signals`, replacing any unwritten
    /// snapshot but never an unwritten purge. Call from inside the lock that
    /// produced the snapshot: that is what makes write order match commit order.
    func persist(_ signals: [Signal]) {
        submit { $0.contents = signals }
    }

    /// Records the intent to erase the queue. Drops any unwritten snapshot, so
    /// a decline cannot be undone by a write already in flight.
    func purge() {
        submit {
            $0.purge = true
            $0.contents = nil
        }
    }

    /// Blocks until every write submitted before the call has reached the
    /// store. A write submitted after it, from any thread, is not promised by
    /// it, and lengthens it by at most one store call, as the type's barrier
    /// describes. Two callers need it: the consumer's deactivation path,
    /// where the process is about to stop being allowed to run, and an erase,
    /// which promises the file is gone rather than that a delete was asked
    /// for.
    ///
    /// Called from the writer's own queue, it waits on itself.
    func waitForPendingWrites() {
        let released = DispatchSemaphore(value: 0)
        guard enqueueWaiter({ released.signal() }) else { return }
        released.wait()
    }

    /// `waitForPendingWrites()` for an async caller: the same barrier, reached
    /// by suspending rather than by parking a thread the cooperative pool
    /// cannot get back.
    ///
    /// Cancellation does not end it early. The erase it stands behind
    /// promises the file is gone, and a cancelled wait that returned first
    /// would let that promise be read before it was kept.
    ///
    /// Named apart from the synchronous form because an async overload of one
    /// name wins in every async context, which would turn each existing
    /// unawaited call there into a compile error.
    func awaitPendingWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !enqueueWaiter({ continuation.resume() }) {
                continuation.resume()
            }
        }
    }

    // MARK: Private

    /// What is still owed to the store. A purge and a snapshot together mean
    /// the snapshot was submitted after the purge, which is the only order
    /// `purge()` leaves them in.
    private struct Pending {
        var purge = false
        var contents: [Signal]?

        var isEmpty: Bool {
            !purge && contents == nil
        }
    }

    /// A caller of the barrier, released once the store has every intent up
    /// to `ticket`.
    private struct Waiter {
        let ticket: UInt64
        let release: @Sendable () -> Void
    }

    /// Everything the lock guards, read and written only inside `withLock`.
    ///
    /// Tickets are what make the barrier exact. Each submit takes the next
    /// one, and a drain that takes `pending` takes the newest ticket with it,
    /// because what it takes is the merge of every intent up to that one. A
    /// wait for "nothing pending" instead lasts as long as anyone keeps
    /// submitting, and a wait for "the queue has run what it holds" can run
    /// ahead of a submit that has not reached the queue yet.
    private struct State {
        var pending = Pending()
        var scheduled = false
        var submitted: UInt64 = 0
        var completed: UInt64 = 0
        /// In ticket order, because tickets are taken in submit order.
        var waiters: [Waiter] = []
    }

    private let storage: any SignalQueueStorage
    private let queue: DispatchQueue
    private let state = Mutex(State())

    private func submit(_ update: (inout Pending) -> Void) {
        state.withLock { state in
            update(&state.pending)
            state.submitted += 1
            guard !state.scheduled else { return }
            state.scheduled = true
            // `self` is captured strongly because a snapshot has
            // to outlive the recorder that submitted it: `record` does not wait,
            // so a recorder released before the queue runs would take the writer,
            // and the unwritten signal, down with it.
            queue.async { self.drain() }
        }
    }

    /// Whether the caller has something to wait for. Asked and registered in
    /// one critical section, so a drain cannot complete the ticket between
    /// the question and the registration and leave the waiter unreleased.
    private func enqueueWaiter(_ release: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard state.completed < state.submitted else { return false }
            state.waiters.append(Waiter(ticket: state.submitted, release: release))
            return true
        }
    }

    /// Runs on `queue`. Keeps writing what is pending until nothing is left,
    /// so a burst submitted while a write is in flight still coalesces into
    /// one dispatch rather than queuing one closure per submit. Releases each
    /// waiter as the write covering its ticket lands, not when the drain
    /// goes idle.
    private func drain() {
        while true {
            let taken: (next: Pending, ticket: UInt64)? = state.withLock { state in
                guard !state.pending.isEmpty else {
                    state.scheduled = false
                    return nil
                }
                defer { state.pending = Pending() }
                return (state.pending, state.submitted)
            }
            guard let taken else { return }
            if taken.next.purge {
                storage.purge()
            }
            if let signals = taken.next.contents {
                storage.persist(signals)
            }
            let released = state.withLock { state in
                state.completed = taken.ticket
                let covered = state.waiters.prefix { $0.ticket <= taken.ticket }
                state.waiters.removeFirst(covered.count)
                return covered
            }
            // Outside the lock: a released caller may submit straight away.
            released.forEach { $0.release() }
        }
    }
}

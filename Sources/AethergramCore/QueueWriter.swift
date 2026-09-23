import Foundation

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
/// of writes is the order of the mutations that produced them; the work happens
/// on one serial queue.
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
/// **What this costs.** The write no longer completes before `record` returns,
/// so a kill in the microseconds between them loses that signal where the
/// synchronous version would not have. `flush()` closes that window at the one
/// moment it is known to matter, by waiting for pending writes on the way out.
final class QueueWriter: @unchecked Sendable {
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

    /// Waits for any pending write to reach the store.
    ///
    /// Bounded by the operation in flight plus at most one purge and one
    /// persist behind it, each as long as the store takes. Two callers need
    /// that: the consumer's deactivation path, where the process is about to stop being
    /// allowed to run, and an erase, which promises the file is gone rather
    /// than that a delete was asked for.
    func waitForPendingWrites() {
        queue.sync {}
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

    private let storage: any SignalQueueStorage
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending = Pending()
    private var scheduled = false

    private func submit(_ update: (inout Pending) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        update(&pending)
        guard !scheduled else { return }
        scheduled = true
        // Dispatched inside the lock: unlocking first leaves a window where a
        // concurrent `waitForPendingWrites()` returns before this intent is on
        // the queue at all. `self` is captured strongly because a snapshot has
        // to outlive the recorder that submitted it: `record` does not wait,
        // so a recorder released before the queue runs would take the writer,
        // and the unwritten signal, down with it.
        queue.async { self.drain() }
    }

    /// Runs on `queue`. Keeps writing what is pending until nothing is left,
    /// so a burst submitted while a write is in flight still coalesces into
    /// one dispatch rather than queuing one closure per submit.
    private func drain() {
        while true {
            lock.lock()
            let next = pending
            guard !next.isEmpty else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = Pending()
            lock.unlock()
            if next.purge {
                storage.purge()
            }
            if let signals = next.contents {
                storage.persist(signals)
            }
        }
    }
}

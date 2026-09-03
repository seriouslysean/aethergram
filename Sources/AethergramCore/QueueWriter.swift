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
/// **Coalescing is the point, not an optimization.** Only the newest intent is
/// ever written: a burst of ten records produces one file write, because each
/// snapshot supersedes the last. That is sound because a snapshot is the whole
/// queue rather than a delta — there is nothing in an older one that a newer
/// one lacks. A purge is modelled as an intent too, so a stale snapshot can
/// never overtake it and resurrect what a decline erased.
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

    /// Records the intent to persist `signals`. Call from inside the lock that
    /// produced the snapshot: that is what makes write order match commit order.
    func persist(_ signals: [Signal]) {
        submit(.contents(signals))
    }

    /// Records the intent to erase the queue. Supersedes any unwritten
    /// snapshot, so a decline cannot be undone by a write already in flight.
    func purge() {
        submit(.purge)
    }

    /// Waits for any pending write to reach disk.
    ///
    /// Bounded by one encode and one atomic write, and used only on the
    /// consumer's deactivation path, where the process is about to stop being
    /// allowed to run and durability is the whole point of the queue.
    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: Private

    private enum Intent {
        case contents([Signal])
        case purge
    }

    private let storage: any SignalQueueStorage
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Intent?
    private var scheduled = false

    private func submit(_ intent: Intent) {
        lock.lock()
        pending = intent
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        queue.async { [weak self] in
            self?.drain()
        }
    }

    /// Runs on `queue`. Keeps writing the newest pending intent until none is
    /// left, so a burst submitted while a write is in flight still coalesces
    /// into one dispatch rather than queuing one closure per submit.
    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            switch next {
            case let .contents(signals): storage.persist(signals)
            case .purge: storage.purge()
            }
        }
    }
}

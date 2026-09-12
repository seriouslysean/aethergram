import Foundation
import os

/// Durable backing for the pending-signal queue.
///
/// A protocol rather than a concrete type because where the queue lives is
/// host-specific: an app extension writes to its own Application Support
/// directory, a host app may want somewhere else, and tests want memory.
///
/// `load()` is called under the recorder's non-recursive lock, and `persist`
/// and `purge` run on the writer queue that an erase and `flush()` wait on, so
/// a conformance must not call back into the recorder: doing so deadlocks.
public protocol SignalQueueStorage: Sendable {
    /// Everything persisted and not yet delivered. Empty on first read and
    /// after `purge()`.
    func load() -> [Signal]

    /// Replaces the persisted queue wholesale. Callers pass the full pending
    /// set, so a partial write can never leave the queue half-updated.
    func persist(_ signals: [Signal])

    /// Deletes the persisted queue. Called on a decline and on a data reset;
    /// after this the store must read back empty, not stale.
    func purge()
}

/// Atomic-file queue storage.
///
/// `Data.write(to:options:[.atomic])` returns only once the bytes are on disk,
/// which is what survives the SIGKILL the OS hands a suspended extension
/// without warning. A buffered write would lose the queue at exactly the
/// moment the queue exists to survive.
public struct FileSignalQueueStorage: SignalQueueStorage {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - directory: Created if absent. The consumer picks it, because a
    ///     package cannot know which container the host is allowed to write to.
    ///   - filename: Overridable so two consumers in one process cannot collide.
    ///   - logSubsystem: The host's logging subsystem; the package has none of
    ///     its own to avoid a constant that means nothing in another app.
    public init(
        directory: URL,
        filename: String = "aethergram-signal-queue.json",
        logSubsystem: String
    ) {
        fileURL = directory.appendingPathComponent(filename)
        logger = Logger(subsystem: logSubsystem, category: "aethergram-queue")
    }

    // MARK: Public

    public func load() -> [Signal] {
        // A purge that reached neither the delete nor the overwrite leaves
        // this behind, and it outlives the process that wrote it. Until the
        // delete lands, what is in the file was collected under an answer
        // that has since been withdrawn, and restoring it is the one thing
        // this store must never do.
        guard !FileManager.default.fileExists(atPath: erasureURL.path) else {
            purge()
            return []
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Reading and decoding fail for opposite reasons. A file this
            // process cannot read right now — protected while the device is
            // locked, a container momentarily out of reach — holds a queue
            // that is still good, and purging it would destroy signals
            // nothing was wrong with. It stays, and the writes stay off it
            // until an erase or another process settles what it holds.
            unread.mark()
            logger.error("queue read fail \(error.localizedDescription, privacy: .public)")
            return []
        }
        do {
            return try JSONDecoder().decode([Signal].self, from: data)
        } catch {
            // A queue we cannot decode is a queue we cannot send, and it will
            // not decode later either. Dropping it beats retrying a corrupt
            // file on every launch forever.
            logger.error("queue decode fail \(error.localizedDescription, privacy: .public)")
            purge()
            return []
        }
    }

    public func persist(_ signals: [Signal]) {
        // Ahead of the empty case on purpose: an empty queue reaches here as
        // a purge, and a purge is exactly what an unread file must not get.
        // What this costs is durability for as long as the read keeps
        // failing — the signals in memory still transmit, they just have
        // nothing on disk to survive a kill — which is the cheaper half of
        // the trade against deleting a queue that was only unreadable.
        guard !unread.isOutstanding else {
            logger.error("queue persist skip reason=unread-queue-on-disk")
            return
        }
        guard !signals.isEmpty else {
            purge()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(signals)
            try data.write(to: fileURL, options: [.atomic])
            // Whatever an earlier purge could not reach is gone: this write
            // replaced it. The mark goes with it, or the next load would
            // purge a queue that is ours.
            settleErasure()
            logger.debug("queue persist ok count=\(signals.count)")
        } catch {
            logger.error("queue persist fail \(error.localizedDescription, privacy: .public)")
        }
    }

    public func purge() {
        // An erase outranks a read this instance could not make: the file goes
        // whether or not its contents were ever known, and the writes resume
        // for whatever is recorded next.
        defer { unread.clear() }
        guard emptyTheQueueFile() else {
            // Nothing this store can do reaches those bytes. What it can do is
            // leave the fact beside them, durably: this process refusing to
            // re-read the file ends when the process does, and the next one
            // would restore a declined-era queue under a later grant.
            requireErasure()
            return
        }
        settleErasure()
    }

    // MARK: Private

    private let fileURL: URL
    private let logger: Logger
    private let unread = UnreadQueueFile()

    /// Sibling of the queue file, because what failed is every write to the
    /// queue file itself. Its presence is the whole message; it has no
    /// contents.
    private var erasureURL: URL {
        fileURL.appendingPathExtension("erase-required")
    }

    /// Whether the queue file holds nothing by the time this returns.
    private func emptyTheQueueFile() -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("queue purge ok")
            return true
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // Nothing persisted yet. Purging is still the right postcondition.
            return true
        } catch {
            // Removal can fail on a directory that refuses it while the file
            // itself still accepts writes. Overwriting in place reaches the
            // same postcondition: nothing left to restore under a later grant.
            // Non-atomic, deliberately — an atomic write needs a temp file in
            // this same directory, which the failure above already refused.
            do {
                try Data("[]".utf8).write(to: fileURL)
                logger.info("queue purge ok via overwrite")
                return true
            } catch {
                logger.error("queue purge fail \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    private func requireErasure() {
        do {
            try Data().write(to: erasureURL)
            logger.error("queue purge unreachable, erasure marked")
        } catch {
            logger.error("queue erasure mark fail \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Takes the mark off. A debt rather than a tombstone: left standing it
    /// would end restoration for this directory permanently.
    private func settleErasure() {
        // Asked before it is done, because the ordinary case is that nothing
        // was ever marked and this runs on every write: a stat costs less than
        // an error to throw away.
        guard FileManager.default.fileExists(atPath: erasureURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: erasureURL)
        } catch {
            logger.error("queue erasure mark clear fail \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Whether this store left a queue on disk it could not read.
///
/// A reference rather than a `var`, because the store is a value a caller may
/// copy and the fact is about the file: two copies over one path describe the
/// same queue. It is deliberately not durable — a read that failed here says
/// nothing about the next process, which retries it.
private final class UnreadQueueFile: Sendable {
    var isOutstanding: Bool {
        outstanding.withLock { $0 }
    }

    func mark() {
        outstanding.withLock { $0 = true }
    }

    func clear() {
        outstanding.withLock { $0 = false }
    }

    private let outstanding = OSAllocatedUnfairLock(initialState: false)
}

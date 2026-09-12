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
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("queue purge ok")
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // Nothing persisted yet. Purging is still the right postcondition.
        } catch {
            // Removal can fail on a directory that refuses it while the file
            // itself still accepts writes. Overwriting in place reaches the
            // same postcondition: nothing left to restore under a later grant.
            // Non-atomic, deliberately — an atomic write needs a temp file in
            // this same directory, which the failure above already refused.
            do {
                try Data("[]".utf8).write(to: fileURL)
                logger.info("queue purge ok via overwrite")
            } catch {
                logger.error("queue purge fail \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Private

    private let fileURL: URL
    private let logger: Logger
    private let unread = UnreadQueueFile()
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

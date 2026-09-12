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
///
/// One store backs one recorder, and it owns what it is backed by. Two live
/// stores over one file — in one process or two — is not a configuration this
/// supports: whatever a conformance holds back is its own, and the second
/// store cannot see it.
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
///
/// It owns its file, in the sense the protocol describes. Two of the refusals
/// it can be carrying are the instance's own — a queue it could not read, and
/// an erase that reached neither the bytes nor a mark — so a second live store
/// over the same path has neither and would write over what the first is
/// protecting. A copy of one store is the same store and shares both; a store
/// constructed separately is not. Give a second consumer in one process a
/// `filename` of its own, and give a second process a container of its own.
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
        file.withLock { loadLocked() }
    }

    public func persist(_ signals: [Signal]) {
        file.withLock { persistLocked(signals) }
    }

    public func purge() {
        file.withLock { purgeLocked() }
    }

    // MARK: Private

    private let fileURL: URL
    private let logger: Logger
    private let file = QueueFile()

    /// Sibling of the queue file, because what failed is every write to the
    /// queue file itself. Its presence is the whole message; it has no
    /// contents.
    private var erasureURL: URL {
        fileURL.appendingPathExtension("erase-required")
    }

    /// Whether an erase this store was told to make has still not reached the
    /// bytes, asked through a call that can fail rather than through
    /// `fileExists`, which answers "no" both for a mark that is not there and
    /// for a directory it could not look inside.
    ///
    /// Three answers rather than two, because "cannot tell" is not "owed" —
    /// reading it as one would make a container that goes briefly out of reach
    /// a decline, and delete the queue on the strength of a question nobody
    /// could answer. It is not permission to restore either. It is the same
    /// position as a queue that cannot be read: hand nothing back, take
    /// nothing away.
    private func erasureMark() -> ErasureMark {
        guard !file.erasureOutstanding else { return .standing }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: erasureURL.path)
            return .standing
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            logger.error("queue erasure mark check fail \(error.localizedDescription, privacy: .public)")
            return .unknown
        }
    }

    private func loadLocked() -> [Signal] {
        // An erase that never landed outranks whatever the file holds: those
        // signals were collected under an answer that has since been
        // withdrawn, and restoring them is the one thing this store must never
        // do. Retried here because the refusal that stopped it may be over.
        switch erasureMark() {
        case .standing:
            purgeLocked()
            return []
        case .unknown:
            file.isUnread = true
            return []
        case .absent:
            break
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Asked by reading rather than by `fileExists`, which answers "no"
            // both for a container that holds no queue and for one this
            // process cannot reach — opposite facts under one answer.
            file.isUnread = false
            return []
        } catch {
            // Reading and decoding fail for opposite reasons. A file this
            // process cannot read right now — protected while the device is
            // locked, a container momentarily out of reach — holds a queue
            // that is still good, and purging it would destroy signals nothing
            // was wrong with. It stays, and the writes stay off it until a
            // read succeeds or an erase supersedes it.
            file.isUnread = true
            logger.error("queue read fail \(error.localizedDescription, privacy: .public)")
            return []
        }
        // What is on disk is known again, so the reason to hold the writes off
        // it is gone. Left standing it would cost this process every write it
        // had left.
        file.isUnread = false
        do {
            return try JSONDecoder().decode([Signal].self, from: data)
        } catch {
            // A queue we cannot decode is a queue we cannot send, and it will
            // not decode later either. Dropping it beats retrying a corrupt
            // file on every launch forever.
            logger.error("queue decode fail \(error.localizedDescription, privacy: .public)")
            purgeLocked()
            return []
        }
    }

    private func persistLocked(_ signals: [Signal]) {
        // An unfinished erase is a prerequisite rather than a state to write
        // alongside. Finishing it first is what stops a queue of ours from
        // sitting under a mark that the next load would purge it for.
        //
        // Ahead of the unread guard because an erase outranks an unread queue
        // everywhere else here too — `purgeLocked` drops the suspension, and
        // `loadLocked` asks this question first. Nothing currently reaches
        // this line with both true, and ordering it this way is what keeps
        // that from being a fact the next change has to know.
        switch erasureMark() {
        case .standing:
            purgeLocked()
            guard case .absent = erasureMark() else {
                logger.error("queue persist skip reason=erasure-outstanding")
                return
            }
        case .unknown:
            logger.error("queue persist skip reason=erasure-unknown")
            return
        case .absent:
            break
        }
        // Ahead of the empty case on purpose: an empty queue reaches here as a
        // purge, and a purge is exactly what an unread file must not get. What
        // this costs is durability for as long as the read keeps failing — the
        // signals in memory still transmit, they just have nothing on disk to
        // survive a kill — which is the cheaper half of the trade against
        // deleting a queue that was only unreadable.
        guard !file.isUnread else {
            logger.error("queue persist skip reason=unread-queue-on-disk")
            return
        }
        guard !signals.isEmpty else {
            purgeLocked()
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

    private func purgeLocked() {
        // An erase outranks a read this store could not make: the file goes
        // whether or not its contents were ever known, and the writes resume
        // for whatever is recorded next.
        file.isUnread = false
        guard emptyTheQueueFile() else {
            // Nothing this store can do reaches those bytes. What it can do is
            // say so — durably where the mark can be written, and in memory
            // regardless, because a refusal that stops the delete and the
            // overwrite stops the mark too.
            markErasureRequired()
            file.erasureOutstanding = true
            return
        }
        file.erasureOutstanding = !clearErasureMark()
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

    private func markErasureRequired() {
        do {
            try Data().write(to: erasureURL)
            logger.error("queue purge unreachable, erasure marked")
        } catch {
            logger.error("queue erasure mark fail \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether no mark is left standing. A debt rather than a tombstone: one
    /// left in place would end restoration for this directory permanently.
    private func clearErasureMark() -> Bool {
        // Attempted rather than asked about first, for the reason above: a
        // removal that fails because there was nothing there is the only
        // failure that settles the debt, and an existence check cannot tell
        // that one from a directory it could not look inside.
        do {
            try FileManager.default.removeItem(at: erasureURL)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return true
        } catch {
            logger.error("queue erasure mark clear fail \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// What a look for the mark a failed erase leaves can come back with.
private enum ErasureMark {
    /// Nothing is owed: no mark, confirmed.
    case absent
    /// An erase reached neither the bytes nor, where it matters, a mark that
    /// outlives this store.
    case standing
    /// The question could not be answered — the directory refused the look.
    case unknown
}

/// The file, as the one thing two copies of the store share.
///
/// It carries the lock that serializes a read, a write and an erase against
/// each other — a guarded flag on its own leaves the operation it authorises
/// racing whatever runs next, and this store's whole job is that nothing
/// overwrites what another call is protecting — and the two facts that outlive
/// a call: a queue on disk this store could not read, and an erase that
/// reached neither the bytes nor a durable mark. Both are read and written
/// only inside `withLock`.
///
/// A reference rather than a value because the store is a struct a caller may
/// copy, and every one of those facts is about the file: two copies over one
/// path are two views of one queue. Neither fact is durable — a read that
/// failed here says nothing about the next process, which retries it, and the
/// mark is what carries an erase across one.
private final class QueueFile: @unchecked Sendable {
    var isUnread = false
    var erasureOutstanding = false

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private let lock = NSLock()
}

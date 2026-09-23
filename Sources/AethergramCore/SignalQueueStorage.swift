import Foundation
import os

/// Durable backing for the pending-signal queue.
///
/// A protocol rather than a concrete type because where the queue lives is
/// host-specific: an app extension writes to its own Application Support
/// directory, a host app may want somewhere else, and tests want memory.
///
/// A conformance must not call back into the recorder. `load()` is called
/// under the recorder's non-recursive lock, where a call back in fails a
/// precondition and terminates the process. `persist` and `purge` run on the
/// writer queue that `flush()`, `reset()` and a decline wait on, where a call
/// back into one of those waits on the queue it is running on.
///
/// One store backs one recorder, and it owns what it is backed by. Two live
/// stores over one file — in one process or two — is not a configuration this
/// supports: whatever a conformance holds back is its own, and the second
/// store cannot see it.
public protocol SignalQueueStorage: Sendable {
    /// Everything persisted and not yet delivered. Empty on first read and
    /// after `purge()`.
    ///
    /// `Signal`'s `Codable` form is not API: a conformance that stores it
    /// encoded must treat a decode failure as an empty queue rather than
    /// trap, as `FileSignalQueueStorage` does.
    func load() -> [Signal]

    /// Replaces the persisted queue wholesale. Callers pass the full pending
    /// set, so a partial write can never leave the queue half-updated.
    func persist(_ signals: [Signal])

    /// Deletes the persisted queue. Called on every non-granted
    /// `updateConsent`, including one made before anything was granted, and
    /// on a data reset; after this the store must read back empty, not stale.
    func purge()
}

/// Atomic-file queue storage.
///
/// `Data.write(to:options:[.atomic])` writes an auxiliary file and then
/// replaces the queue file with it, so a reader finds the old queue or the new
/// one, never part of either. Once it returns the bytes are the kernel's, not
/// the process's, which is what survives the SIGKILL the OS hands a suspended
/// extension without warning; a write still buffered in the process would lose
/// the queue at exactly the moment the queue exists to survive. That is the
/// whole claim: it is not a promise the bytes reached the storage device.
///
/// It owns its file, in the sense the protocol describes. Three things it can
/// be carrying are the instance's own — a queue it could not read, what a
/// later read of that queue found, and an erase that reached neither the bytes
/// nor a mark — so a second live store over the same path has none of them
/// and would write over what the first is protecting.
///
/// A queue it could not read keeps the writes off the file, and every write
/// retries the read. Once it reads, what the file held, up to the newest
/// `queueLimit` signals of the recorder it backs, is written ahead of every
/// snapshot until a load hands it back or an erase removes it, because the
/// recorder never saw those signals and only a later process can send them.
/// The recorder hands its limit only to a store it is given directly; one
/// reached through another conformance keeps the limit it already has, 1,000
/// unless it or a copy of it was also given to a recorder directly.
/// A copy of one store is the same store and shares all of it; a store
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

    // MARK: Internal

    /// Bounds what a late read carries at the limit of the recorder this
    /// store backs. The recorder calls it at construction; a store never
    /// given one keeps the default.
    func adoptQueueLimit(_ limit: Int) {
        file.withLock { file.queueLimit = limit }
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
        // Reachability rather than attributes, because the answer is presence
        // alone and the attribute calls return file timestamps. A `false`
        // rather than a throw is a look that did not answer, never an erase
        // owed.
        let mark: ErasureMark
        do {
            mark = try erasureURL.checkResourceIsReachable() ? .standing : .unknown
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            mark = .absent
        } catch {
            // Asked on every write, so logged when the look starts failing
            // rather than each time it still does.
            if !file.markLookFailing {
                logger.error("queue erasure mark check fail \(error.localizedDescription, privacy: .public)")
            }
            file.markLookFailing = true
            return .unknown
        }
        file.markLookFailing = false
        return mark
    }

    private func loadLocked() -> [Signal] {
        // A load answers for the whole file, carried signals included: it
        // hands them back, erases them, or cannot read them — and then a late
        // read takes them from the file again.
        file.carried = []
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
        switch readQueueFile() {
        case .absent:
            file.isUnread = false
            return []
        case let .unreadable(error):
            // Reading and decoding fail for opposite reasons. A file this
            // process cannot read right now — protected while the device is
            // locked, a container momentarily out of reach — holds a queue
            // that is still good, and purging it would destroy signals nothing
            // was wrong with. It stays, and the writes stay off it until a
            // read succeeds or an erase supersedes it.
            file.isUnread = true
            logger.error("queue read fail \(error.localizedDescription, privacy: .public)")
            return []
        case let .undecodable(error):
            // A queue we cannot decode is a queue we cannot send, and it will
            // not decode later either. Dropping it beats retrying a corrupt
            // file on every launch forever.
            logger.error("queue decode fail \(error.localizedDescription, privacy: .public)")
            purgeLocked()
            return []
        case let .signals(signals):
            file.isUnread = false
            return signals
        }
    }

    /// What the queue file holds, asked by reading rather than by
    /// `fileExists`, which answers "no" both for a container that holds no
    /// queue and for one this process cannot reach — opposite facts under one
    /// answer.
    private func readQueueFile() -> QueueRead {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable(error)
        }
        do {
            return try .signals(JSONDecoder().decode([Signal].self, from: data))
        } catch {
            return .undecodable(error)
        }
    }

    /// Whether the writes may go over the queue file, retrying the read a
    /// failed one left owed.
    ///
    /// Retried here because nothing else would: the recorder loads once, so a
    /// read that failed is never asked again by that process, and holding the
    /// writes until it is would cost every write it had left.
    /// Retried silently, because it runs on every write while the file stays
    /// out of reach.
    ///
    /// A read that succeeds here hands nothing back — the caller is writing,
    /// not loading — so the newest of what the file held become `carried`,
    /// and go ahead of every snapshot until a load or an erase. That is what
    /// keeps those signals for the next process, the only one that can send
    /// them.
    private func settleUnreadQueue() -> Bool {
        guard file.isUnread else { return true }
        switch readQueueFile() {
        case .unreadable:
            return false
        case .absent:
            file.isUnread = false
        case let .undecodable(error):
            logger.error("queue decode fail \(error.localizedDescription, privacy: .public)")
            purgeLocked()
            // A corrupt file the purge could not reach is under a mark now,
            // and a write under a mark is one the next load erases.
            return !file.erasureOutstanding
        case let .signals(signals):
            file.isUnread = false
            // Newest kept, matching the recorder's own eviction: these are
            // the oldest signals the file holds, and a run of processes that
            // each carry everything before them would otherwise grow the file
            // by a snapshot apiece.
            let limit = file.queueLimit
            file.carried = Array(signals.suffix(limit))
            if signals.count > limit {
                logger.error("queue read recovered count=\(signals.count) dropped=\(signals.count - limit)")
            } else {
                logger.info("queue read recovered count=\(signals.count)")
            }
        }
        return true
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
                skipPersist(.erasureOutstanding)
                return
            }
        case .unknown:
            skipPersist(.erasureUnknown)
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
        guard settleUnreadQueue() else {
            skipPersist(file.erasureOutstanding ? .erasureOutstanding : .unreadQueueOnDisk)
            return
        }
        resumePersist()
        // The snapshot is the recorder's whole queue, and `carried` is what
        // the file held that the recorder never saw, so neither replaces the
        // other. An empty snapshot is "everything delivered", which says
        // nothing about signals the recorder never had.
        let queue = file.carried + signals
        guard !queue.isEmpty else {
            purgeLocked()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(queue)
            try data.write(to: fileURL, options: [.atomic])
            logger.debug("queue persist ok count=\(queue.count)")
        } catch {
            logger.error("queue persist fail \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Logs a skipped write when the skipping starts, or its reason changes,
    /// rather than on every write it costs: while the file stays out of reach
    /// every record lands here, and each error line is one unified logging
    /// keeps.
    private func skipPersist(_ reason: PersistSkip) {
        guard file.persistSkip != reason else { return }
        file.persistSkip = reason
        logger.error("queue persist skip reason=\(reason.rawValue, privacy: .public)")
    }

    /// The other end of `skipPersist`: once, when a write goes ahead again.
    private func resumePersist() {
        guard let reason = file.persistSkip else { return }
        file.persistSkip = nil
        logger.info("queue persist resume after=\(reason.rawValue, privacy: .public)")
    }

    private func purgeLocked() {
        // An erase outranks a read this store could not make: the file goes
        // whether or not its contents were ever known, and the writes resume
        // for whatever is recorded next. What a late read rescued goes with
        // it, having been collected under the same answer.
        file.isUnread = false
        file.carried = []
        guard emptyTheQueueFile() else {
            // A file is there, or cannot be ruled out, and nothing this store
            // can do reaches its bytes. What it can do is
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
            return overwriteInPlace()
        }
    }

    /// Whether the queue file holds nothing, reached by writing over it where
    /// it stands.
    ///
    /// Opened without creating: a purge runs on a decline before anything was
    /// granted, and a file it made would be a write consent never allowed. A
    /// file that is not there needs no overwrite and leaves nothing to mark.
    /// Any other refusal cannot rule a file out, so it counts as one the
    /// erase did not reach. Non-atomic, deliberately — an atomic write needs a
    /// temp file in this same directory, which the failed delete already
    /// refused.
    private func overwriteInPlace() -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return true
        } catch {
            logger.error("queue purge fail \(error.localizedDescription, privacy: .public)")
            return false
        }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("[]".utf8))
            logger.info("queue purge ok via overwrite")
            return true
        } catch {
            logger.error("queue purge fail \(error.localizedDescription, privacy: .public)")
            return false
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

/// What a read of the queue file can come back with. Four answers, because
/// each asks something different of the caller: nothing to restore, a queue
/// still good but out of reach, a queue that will never decode, and a queue.
private enum QueueRead {
    case absent
    case unreadable(Error)
    case undecodable(Error)
    case signals([Signal])
}

/// Why a write did not reach the file.
private enum PersistSkip: String {
    case erasureOutstanding = "erasure-outstanding"
    case erasureUnknown = "erasure-unknown"
    case unreadQueueOnDisk = "unread-queue-on-disk"
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
/// overwrites what another call is protecting — and the facts that outlive a
/// call: a queue on disk this store could not read, what a later read of it
/// found, and an erase that reached neither the bytes nor a durable mark. All
/// are read and written only inside `withLock`.
///
/// A reference rather than a value because the store is a struct a caller may
/// copy, and every one of those facts is about the file: two copies over one
/// path are two views of one queue. None of them is durable — a read that
/// failed here says nothing about the next process, which retries it, what a
/// late read found is in the file for that process to load, and the mark is
/// what carries an erase across one.
private final class QueueFile: @unchecked Sendable {
    var isUnread = false
    var erasureOutstanding = false
    /// What the file held when a read first succeeded after a failed one:
    /// signals no load handed back, so no snapshot contains them. Written
    /// ahead of every snapshot until a load or an erase.
    ///
    /// A late read replaces it rather than adding to it, and keeps only the
    /// newest `queueLimit`: without a bound each process in a row whose load
    /// fails and whose later read succeeds would carry everything before it
    /// and grow the file by a snapshot. The file stays within that bound plus
    /// one snapshot until the first process whose load succeeds, whose restore
    /// trims it to its own limit oldest-first.
    var carried: [Signal] = []
    /// The recorder's `queueLimit`, handed over when it takes the store, and
    /// the default until then.
    var queueLimit = AethergramConfiguration.defaultQueueLimit
    /// Log bookkeeping only, so a degraded store says so once rather than on
    /// every write: why writes are being skipped, and whether the look for
    /// the mark is failing.
    var persistSkip: PersistSkip?
    var markLookFailing = false

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private let lock = NSLock()
}

import Foundation
import os

/// Durable backing for the pending-signal queue.
///
/// A protocol rather than a concrete type because where the queue lives is
/// host-specific: an app extension writes to its own Application Support
/// directory, a host app may want somewhere else, and tests want memory.
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
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Signal].self, from: data)
        } catch {
            // A queue we cannot decode is a queue we cannot send. Dropping it
            // beats retrying a corrupt file on every launch forever.
            logger.error("queue load fail \(error.localizedDescription, privacy: .public)")
            purge()
            return []
        }
    }

    public func persist(_ signals: [Signal]) {
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
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("queue purge ok")
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // Nothing persisted yet. Purging is still the right postcondition.
        } catch {
            logger.error("queue purge fail \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Private

    private let fileURL: URL
    private let logger: Logger
}

@testable import AethergramCore
import Foundation

/// The device's file operations over a real directory, with faults a test
/// scripts ahead of the call they hit, and a log of every call that reached
/// it.
///
/// Every call a fault does not stop goes to the production conformance, so a
/// guard broken in production code fails the test that relies on it.
final class FaultingFileOperations: QueueFileOperations, @unchecked Sendable {
    // MARK: Internal

    enum Operation: Equatable {
        case read
        case replace
        case remove
        case overwrite
        case markerReachable
        case writeMarker
        case removeMarker
        case createDirectory

        /// Whether the call can change what is on disk.
        var writes: Bool {
            switch self {
            case .read, .markerReachable: false
            default: true
            }
        }
    }

    enum Fault {
        /// Throws before touching the file.
        case refuse(Error)
    }

    /// Every call that can change the disk, in order, since the last `clear`.
    var writes: [Operation] {
        lock.withLock { log.filter(\.writes) }
    }

    /// Faults the next `times` calls of `operation`, in the order scripted.
    func script(_ operation: Operation, _ fault: Fault, times: Int = 1) {
        lock.withLock { faults[operation, default: []] += Array(repeating: fault, count: times) }
    }

    func clear() {
        lock.withLock { log.removeAll() }
    }

    func read(_ url: URL) throws -> Data {
        try enter(.read)
        return try real.read(url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try enter(.replace)
        try real.replaceAtomically(data, at: url)
    }

    func remove(_ url: URL) throws {
        try enter(.remove)
        try real.remove(url)
    }

    func overwriteInPlace(_ data: Data, at url: URL) throws {
        try enter(.overwrite)
        try real.overwriteInPlace(data, at: url)
    }

    func markerReachable(_ url: URL) throws -> Bool {
        try enter(.markerReachable)
        return try real.markerReachable(url)
    }

    func writeMarker(_ url: URL) throws {
        try enter(.writeMarker)
        try real.writeMarker(url)
    }

    func removeMarker(_ url: URL) throws {
        try enter(.removeMarker)
        try real.removeMarker(url)
    }

    func createDirectory(_ url: URL) throws {
        try enter(.createDirectory)
        try real.createDirectory(url)
    }

    // MARK: Private

    private let real = FoundationQueueFileOperations()
    private let lock = NSLock()
    private var log: [Operation] = []
    private var faults: [Operation: [Fault]] = [:]

    /// Logs the call and applies its next scripted fault, if any.
    private func enter(_ operation: Operation) throws {
        let fault: Fault? = lock.withLock {
            log.append(operation)
            guard var queued = faults[operation], !queued.isEmpty else { return nil }
            let next = queued.removeFirst()
            faults[operation] = queued
            return next
        }
        if case let .refuse(error) = fault { throw error }
    }
}

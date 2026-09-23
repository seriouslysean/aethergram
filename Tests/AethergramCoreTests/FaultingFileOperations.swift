@testable import AethergramCore
import Foundation

/// The device's file operations over a real directory, with faults a test
/// scripts ahead of the call they hit, and a log of every call that reached
/// it.
///
/// Every call a fault does not stop goes to the production conformance, so a
/// partial append lands through the same handle a device uses and a guard
/// broken in production code fails the test that relies on it.
final class FaultingFileOperations: QueueFileOperations, @unchecked Sendable {
    // MARK: Internal

    enum Operation: Equatable {
        case read
        case append
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
        /// Writes the first `bytes` of what it was given for real, then
        /// throws: the shape a kill or a full disk leaves.
        case partial(bytes: Int, then: Error)
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
        try enter(.read) { _ in }
        return try real.read(url)
    }

    func append(_ data: Data, to url: URL) throws {
        try enter(.append) { try real.append(data.prefix($0), to: url) }
        try real.append(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try enter(.replace) { _ in }
        try real.replaceAtomically(data, at: url)
    }

    func remove(_ url: URL) throws {
        try enter(.remove) { _ in }
        try real.remove(url)
    }

    func overwriteInPlace(_ data: Data, at url: URL) throws {
        try enter(.overwrite) { try real.overwriteInPlace(data.prefix($0), at: url) }
        try real.overwriteInPlace(data, at: url)
    }

    func markerReachable(_ url: URL) throws -> Bool {
        try enter(.markerReachable) { _ in }
        return try real.markerReachable(url)
    }

    func writeMarker(_ url: URL) throws {
        try enter(.writeMarker) { _ in }
        try real.writeMarker(url)
    }

    func removeMarker(_ url: URL) throws {
        try enter(.removeMarker) { _ in }
        try real.removeMarker(url)
    }

    func createDirectory(_ url: URL) throws {
        try enter(.createDirectory) { _ in }
        try real.createDirectory(url)
    }

    // MARK: Private

    private let real = FoundationQueueFileOperations()
    private let lock = NSLock()
    private var log: [Operation] = []
    private var faults: [Operation: [Fault]] = [:]

    /// Logs the call and applies its next scripted fault, if any. `partial`
    /// writes the prefix it is handed the byte count for.
    private func enter(_ operation: Operation, partial: (Int) throws -> Void) throws {
        let fault: Fault? = lock.withLock {
            log.append(operation)
            guard var queued = faults[operation], !queued.isEmpty else { return nil }
            let next = queued.removeFirst()
            faults[operation] = queued
            return next
        }
        switch fault {
        case nil:
            return
        case let .refuse(error):
            throw error
        case let .partial(bytes, error):
            try partial(bytes)
            throw error
        }
    }
}

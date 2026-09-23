@testable import AethergramCore
import AethergramTestSupport
import Foundation
import Testing

/// A wait on one submission's ticket ends when a write covering that
/// submission lands, and neither earlier nor later. A removal checkpointed by
/// one write must not wait for records submitted after it, and must not
/// return before its own write, which may have been folded into a later one.
///
/// Every interleaving here is pinned by holding the store's calls open, so no
/// assertion rests on timing; the bounded sleeps only give a wrongly released
/// waiter time to show itself.
@Suite("Queue writer tickets", .serialized, .timeLimit(.minutes(1)), .tags(.persistence, .lifecycle))
struct QueueWriterTicketTests {
    @Test("A wait on a submission's ticket does not wait for writes submitted after it")
    func ticketWaitIgnoresLaterWrites() async throws {
        let storage = HoldingStorage()
        let writer = QueueWriter(storage: storage, label: "queue-writer-ticket-tests")
        let first = storage.holdNextPersist()
        let ticket = writer.persist([named("a")])
        await first.entered.wait()
        let second = storage.holdNextPersist()
        writer.persist([named("b")])

        let returned = Gate()
        let waiting = Task {
            await writer.awaitWrites(through: ticket)
            returned.open()
        }
        first.release()
        await returned.wait()

        // "b" is held open on the store, so a wait that covered it could not
        // have returned.
        #expect(storage.events == ["persist a"])
        second.release()
        await waiting.value
        await writer.awaitPendingWrites()
        #expect(storage.events == ["persist a", "persist b"])
    }

    @Test("A wait on a submission's ticket waits for the write it was folded into")
    func ticketWaitCoversACoalescedWrite() async throws {
        let storage = HoldingStorage()
        let writer = QueueWriter(storage: storage, label: "queue-writer-ticket-tests")
        let first = storage.holdNextPersist()
        writer.persist([named("a")])
        await first.entered.wait()
        let ticket = writer.persist([named("b")])
        writer.persist([named("c")])

        let returned = Gate()
        let waiting = Task {
            await writer.awaitWrites(through: ticket)
            returned.open()
        }
        let folded = storage.holdNextPersist()
        first.release()
        await folded.entered.wait()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!returned.isOpen)

        folded.release()
        await returned.wait()
        await waiting.value
        // "b" was never written on its own: "c" superseded it, and the wait
        // on "b" is released by the write of "c".
        #expect(storage.events == ["persist a", "persist c"])
    }

    /// A caller waiting on an older ticket can register after one waiting on
    /// a newer ticket. Released in registration order, it would wait for the
    /// newer write too.
    @Test("A wait on an older ticket registered behind a newer one is released by its own write")
    func olderTicketRegisteredLateIsReleasedByItsOwnWrite() async throws {
        let storage = HoldingStorage()
        let writer = QueueWriter(storage: storage, label: "queue-writer-ticket-tests")
        let first = storage.holdNextPersist()
        let older = writer.persist([named("a")])
        await first.entered.wait()
        writer.persist([named("b")])

        let newerReturned = Gate()
        let newer = Task {
            await writer.awaitPendingWrites()
            newerReturned.open()
        }
        try await waitForWaiters(writer, count: 1)
        let olderReturned = Gate()
        let olderWait = Task {
            await writer.awaitWrites(through: older)
            olderReturned.open()
        }
        try await waitForWaiters(writer, count: 2)

        let second = storage.holdNextPersist()
        first.release()
        await olderReturned.wait()
        #expect(!newerReturned.isOpen)
        second.release()
        await newerReturned.wait()
        await olderWait.value
        await newer.value
    }

    /// An erase stands behind this wait, as behind `awaitPendingWrites`.
    @Test("Cancelling a wait on a ticket does not return it before that write lands")
    func cancellingATicketWaitDoesNotEndItEarly() async throws {
        let storage = HoldingStorage()
        let writer = QueueWriter(storage: storage, label: "queue-writer-ticket-tests")
        let held = storage.holdNextPersist()
        let ticket = writer.persist([named("held")])
        await held.entered.wait()

        let returned = Gate()
        let waiting = Task {
            await writer.awaitWrites(through: ticket)
            returned.open()
        }
        waiting.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!returned.isOpen)

        held.release()
        await returned.wait()
        #expect(storage.events == ["persist held"])
    }

    @Test("A wait on a ticket already written returns at once")
    func ticketAlreadyWrittenReturnsAtOnce() async throws {
        let storage = HoldingStorage()
        let writer = QueueWriter(storage: storage, label: "queue-writer-ticket-tests")
        let ticket = writer.persist([named("a")])
        await writer.awaitPendingWrites()

        await writer.awaitWrites(through: ticket)
        #expect(storage.events == ["persist a"])
    }

    /// The barrier's contract, at the one place it waits for more than it
    /// promises: a purge is never superseded, so a snapshot submitted after
    /// it rides in the same drain step, and a waiter whose barrier falls
    /// between them is released only once that snapshot lands too.
    @Test("A waiter registered between a purge and the snapshot folded behind it is released once both land")
    func waiterBetweenPurgeAndFoldedSnapshotWaitsForBoth() async throws {
        let storage = HoldingStorage()
        let writer = QueueWriter(storage: storage, label: "queue-writer-ticket-tests")
        let first = storage.holdNextPersist()
        writer.persist([named("in-flight")])
        await first.entered.wait()
        writer.persist([named("superseded")])
        writer.purge()

        let returned = Gate()
        let waiting = Task {
            await writer.awaitPendingWrites()
            returned.open()
        }
        try await waitForWaiters(writer, count: 1)
        let folded = storage.holdNextPersist()
        writer.persist([named("after")])

        first.release()
        await folded.entered.wait()
        // The purge has landed, which covers everything submitted before the
        // waiter, and the waiter is still held by the snapshot after it.
        #expect(storage.events == ["persist in-flight", "purge"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!returned.isOpen)

        folded.release()
        await returned.wait()
        await waiting.value
        #expect(storage.events == ["persist in-flight", "purge", "persist after"])
    }
}

/// Polls until `count` callers are registered on the writer's barrier, so
/// what a test submits next is known to come after their registration.
private func waitForWaiters(_ writer: QueueWriter, count: Int) async throws {
    while writer.waiterCount < count {
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func named(_ name: String) -> Signal {
    Signal(name: name, sessionID: "session-a", recordedAt: Date(timeIntervalSinceReferenceDate: 0))
}

/// A store that logs each call as it completes and can hold the next
/// `persist` open until released, blocking the writer's queue there.
private final class HoldingStorage: SignalQueueStorage, @unchecked Sendable {
    // MARK: Internal

    /// One held call: `entered` opens once the call is on the store and
    /// blocked, `release` lets it finish.
    final class Hold: Sendable {
        let entered = Gate()

        func release() {
            semaphore.signal()
        }

        fileprivate let semaphore = DispatchSemaphore(value: 0)
    }

    var events: [String] {
        lock.withLock { log }
    }

    func holdNextPersist() -> Hold {
        let hold = Hold()
        lock.withLock { pendingHold = hold }
        return hold
    }

    func load() -> [Signal] {
        []
    }

    func persist(_ signals: [Signal]) {
        let hold: Hold? = lock.withLock {
            defer { pendingHold = nil }
            return pendingHold
        }
        if let hold {
            hold.entered.open()
            hold.semaphore.wait()
        }
        lock.withLock { log.append("persist \(signals.map(\.name).joined(separator: ","))") }
    }

    func purge() {
        lock.withLock { log.append("purge") }
    }

    // MARK: Private

    private let lock = NSLock()
    private var log: [String] = []
    private var pendingHold: Hold?
}

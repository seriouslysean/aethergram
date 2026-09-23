@testable import AethergramCore
import AethergramTestSupport
import Foundation
import Testing

/// A flush and an erase wait for the writes submitted before they were
/// called, and for nothing after. Waiting until nothing is pending gets both
/// halves wrong: another thread recording continuously keeps something pending
/// for as long as it records, so the wait lasts as long as the recording does.
///
/// Every blocking wait here runs on a thread of its own and reports through a
/// gate, because a cooperative thread parked on the writer is one the pool
/// cannot give back, and CI has three.
@Suite("Queue writer barrier", .serialized, .timeLimit(.minutes(1)), .tags(.persistence, .lifecycle))
struct QueueWriterBarrierTests {
    @Test("Recording continuously from another thread does not hold a flush past the writes before it")
    func continuousRecordingDoesNotExtendTheWait() async throws {
        let storage = PacedStorage(pace: 0.005)
        let writer = QueueWriter(storage: storage, label: "queue-writer-barrier-tests")
        let recording = ContinuousRecording(writer: writer, deadline: 2)
        await recording.started.wait()

        let returned = Gate()
        let persistsAtCall = Seen(0)
        let persistsAtReturn = Seen(0)
        Thread.detachNewThread {
            persistsAtCall.value = storage.persistCount
            writer.waitForPendingWrites()
            persistsAtReturn.value = storage.persistCount
            recording.stop()
            returned.open()
        }
        await returned.wait()
        await recording.finished.wait()

        // Known-bad shape kept as the assertion: a wait that lasts until
        // nothing is pending returns only once the recording gives up at its
        // deadline.
        #expect(!recording.reachedDeadline)
        // The write in flight at the call, the one that covers every snapshot
        // submitted before it, and one more for a write finishing between the
        // count and the call.
        #expect(persistsAtReturn.value - persistsAtCall.value <= 3)
    }

    @Test("A write submitted before a flush is on the store when the flush returns")
    func writeBeforeTheWaitIsOnTheStore() async throws {
        let storage = PacedStorage(pace: 0.005)
        let writer = QueueWriter(storage: storage, label: "queue-writer-barrier-tests")
        let signalDate = try testDate(year: 2026, month: 1, day: 5)

        let returned = Gate()
        let seen = Seen<String?>(nil)
        Thread.detachNewThread {
            for index in 0 ..< 20 {
                writer.persist([Signal(name: "burst.\(index)", sessionID: "session-a", recordedAt: signalDate)])
            }
            writer.waitForPendingWrites()
            seen.value = storage.lastPersisted
            returned.open()
        }
        await returned.wait()

        #expect(seen.value == "burst.19")
    }
}

/// A store that takes a fixed time over each persist, so a writer's drain is
/// always mid-write while a submitter outpaces it, and logs what it was last
/// given.
private final class PacedStorage: SignalQueueStorage, @unchecked Sendable {
    // MARK: Lifecycle

    init(pace: TimeInterval) {
        self.pace = pace
    }

    // MARK: Internal

    var persistCount: Int {
        lock.withLock { count }
    }

    var lastPersisted: String? {
        lock.withLock { last }
    }

    func load() -> [Signal] {
        []
    }

    func persist(_ signals: [Signal]) {
        Thread.sleep(forTimeInterval: pace)
        lock.withLock {
            count += 1
            last = signals.last?.name
        }
    }

    func purge() {}

    // MARK: Private

    private let pace: TimeInterval
    private let lock = NSLock()
    private var count = 0
    private var last: String?
}

/// Submits snapshots back to back on a thread of its own until stopped or
/// until its deadline, and says which ended it.
private final class ContinuousRecording: @unchecked Sendable {
    // MARK: Lifecycle

    init(writer: QueueWriter, deadline: TimeInterval) {
        Thread.detachNewThread { [self] in
            let signalDate = Date(timeIntervalSinceReferenceDate: 0)
            let end = Date().addingTimeInterval(deadline)
            var index = 0
            while !isStopped {
                if Date() >= end {
                    lock.withLock { deadlineReached = true }
                    break
                }
                writer.persist([Signal(name: "continuous.\(index)", sessionID: "session-a", recordedAt: signalDate)])
                index += 1
                if index == 1 {
                    started.open()
                }
            }
            started.open()
            finished.open()
        }
    }

    // MARK: Internal

    let started = Gate()
    let finished = Gate()

    var reachedDeadline: Bool {
        lock.withLock { deadlineReached }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    // MARK: Private

    private let lock = NSLock()
    private var stopped = false
    private var deadlineReached = false

    private var isStopped: Bool {
        lock.withLock { stopped }
    }
}

/// What a thread saw, read back by the test body after it.
private final class Seen<Value: Sendable>: @unchecked Sendable {
    // MARK: Lifecycle

    init(_ initial: Value) {
        stored = initial
    }

    // MARK: Internal

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    // MARK: Private

    private let lock = NSLock()
    private var stored: Value
}

@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// A reset that rotates the host's identifier has to keep the gate shut
/// across the rotation, not only across the erase. A reset leaves consent as
/// it was, so without that a signal recorded in the gap is a legitimate
/// signal, and it leaves under the identifier being rotated away from — the
/// linkage the rotation exists to end.
///
/// The records here are made from another thread while the callback runs,
/// because that is where they come from in a host: the callback is on the
/// reset path and the emits are on every other.
@Suite("Reset while collection is closed", .tempDirectory, .serialized, .timeLimit(.minutes(1)), .tags(.consent))
struct ResetWhileClosedTests {
    struct RotationFailed: Error {}

    /// Every layer the recorder touches, not only the transport: a record
    /// dropped before the queue reads no payload, resolves no identifier,
    /// writes nothing, and saves no counter.
    @Test("A record made while the host rotates its identifier is dropped at every layer, not sent")
    func recordDuringTheCallbackIsDropped() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("before")
        var before: [Int] = []
        var after: [Int] = []

        fixture.recorder.resetClosingCollection {
            before = Self.layers(fixture)
            Self.onAnotherThread { fixture.recorder.record("during") }
            after = Self.layers(fixture)
        }
        fixture.recorder.record("after")
        await fixture.recorder.drain()

        #expect(after == before)
        #expect(fixture.transport.sentSignalNames == ["after"])
    }

    /// The identifier is what the rotation replaces, so a drain that resolves
    /// it mid-rotation reads the one being retired, or one half-written.
    @Test("The identifier is not resolved while the host rotates it")
    func identifierIsNotResolvedDuringTheCallback() async throws {
        let directory = try #require(TestTempDirectory.url)
        let rotating = SharedFlag()
        let resolvedWhileRotating = Counter()
        let transport = SpyTransport()
        let recorder = try SignalRecorder(
            configuration: testConfiguration(batchSize: 1, transmitInterval: 3600),
            transport: transport,
            queueStorage: RecordingQueueStorage(directory: directory),
            retentionStore: SpyRetentionStore(),
            clientUserProvider: {
                if rotating.isRaised { resolvedWhileRotating.increment() }
                return "client-user"
            },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        recorder.updateConsent(.granted)

        // On a GCD thread, because the callback holds its thread for the
        // window and a test body parked there would hold a pool thread.
        let resetDone = Gate()
        DispatchQueue.global().async {
            recorder.resetClosingCollection {
                rotating.raise()
                // A full batch asks for a drain at once, so an open gate
                // would resolve the identifier inside this window.
                recorder.record("during")
                Thread.sleep(forTimeInterval: 0.3)
                rotating.lower()
            }
            resetDone.open()
        }
        await resetDone.wait()
        withExtendedLifetime(recorder) {}

        #expect(resolvedWhileRotating.count == 0)
        #expect(!transport.sentSignalNames.contains("during"))
    }

    /// Collection comes back on its own once the callback returns, under a
    /// session nothing before the reset carried, and the counters it opens
    /// are the reset's rather than the erased record's. Every signal after
    /// the reset carries that one session: none leaves under an uncounted
    /// id minted between the erase and the reopen.
    @Test("Collection reopens after the callback under one new counted session")
    func collectionReopensUnderANewCountedSession() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)
        fixture.recorder.beginSession()
        fixture.recorder.record("before")
        await fixture.recorder.drain()

        fixture.recorder.resetClosingCollection {
            Self.onAnotherThread { fixture.recorder.record("during") }
        }
        fixture.recorder.record("after")
        await fixture.recorder.drain()

        let sent = fixture.transport.sentSignals
        #expect(sent.map(\.name) == ["before", "after"])
        #expect(sent.first?.sessionID != sent.last?.sessionID)
        let counters = try #require(fixture.retention.record)
        #expect(counters.totalSessionsCount == 1)
        #expect(counters.openSessionStartedAt != nil)
    }

    /// The reopen restores the answer in force when the callback returns,
    /// not the one in force when the reset began: a decline made meanwhile
    /// is the user's, and a reopen that restored the old grant would turn
    /// collection back on for someone who just turned it off. Nothing
    /// recorded before the decline reaches disk either.
    @Test("A decline made during the callback is not undone by the reopen")
    func declineDuringTheCallbackStands() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)
        let persistsBefore = fixture.storage.persistCallCount

        fixture.recorder.resetClosingCollection {
            Self.onAnotherThread { fixture.recorder.record("during") }
            Self.onAnotherThread { fixture.recorder.updateConsent(.declined) }
        }
        fixture.recorder.record("after")
        fixture.recorder.beginSession()
        await fixture.recorder.drain()

        #expect(fixture.transport.sendCount == 0)
        #expect(fixture.storage.persistCallCount == persistsBefore)
        #expect(fixture.storage.signalsOnDisk.isEmpty)
        #expect(fixture.retention.record == nil)
    }

    /// An inner reset's return is not the outer callback's: the outer
    /// rotation is still running.
    @Test("A nested reset reopens collection only when the outermost callback returns")
    func nestedResetsReopenOnlyAtTheOutermostReturn() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)

        fixture.recorder.resetClosingCollection {
            fixture.recorder.resetClosingCollection {}
            Self.onAnotherThread { fixture.recorder.record("between") }
        }
        fixture.recorder.record("after")
        await fixture.recorder.drain()

        #expect(fixture.transport.sentSignalNames == ["after"])
        #expect(fixture.retention.record?.totalSessionsCount == 1)
    }

    /// Two resets from two threads can finish in either order. The one that
    /// finishes first is not the last one out, whichever it started as.
    @Test("Two concurrent resets reopen collection only when the last one returns, in either order")
    func concurrentResetsFinishingInReverseOrderReopenOnce() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)
        let firstInside = Gate()
        let firstRelease = DispatchSemaphore(value: 0)
        let firstReturned = Gate()
        let secondReturned = Gate()

        DispatchQueue.global().async {
            fixture.recorder.resetClosingCollection {
                firstInside.open()
                firstRelease.wait()
            }
            firstReturned.open()
        }
        await firstInside.wait()
        DispatchQueue.global().async {
            fixture.recorder.resetClosingCollection {}
            secondReturned.open()
        }
        await secondReturned.wait()
        fixture.recorder.record("between")
        firstRelease.signal()
        await firstReturned.wait()
        fixture.recorder.record("after")
        await fixture.recorder.drain()

        #expect(fixture.transport.sentSignalNames == ["after"])
        #expect(fixture.retention.record?.totalSessionsCount == 1)
    }

    /// A regrant during the callback is the answer in force at the reopen,
    /// and it takes effect there rather than in the middle of the rotation.
    @Test("A regrant during the callback opens collection only when the callback returns")
    func regrantDuringTheCallbackWaitsForTheReopen() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)

        fixture.recorder.resetClosingCollection {
            Self.onAnotherThread { fixture.recorder.updateConsent(.declined) }
            Self.onAnotherThread { fixture.recorder.updateConsent(.granted) }
            Self.onAnotherThread { fixture.recorder.record("during") }
        }
        fixture.recorder.record("after")
        await fixture.recorder.drain()

        let sent = fixture.transport.sentSignals
        #expect(sent.map(\.name) == ["after"])
        #expect(fixture.retention.record?.totalSessionsCount == 1)
    }

    /// A session boundary during the rotation would count a session under
    /// the identifier being retired, and close it before the reopen counts
    /// the one that follows.
    @Test("Session calls during the callback are dropped, and the reopen counts one session")
    func sessionCallsDuringTheCallbackAreDropped() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)
        fixture.recorder.beginSession()

        fixture.recorder.resetClosingCollection {
            Self.onAnotherThread {
                fixture.recorder.beginSession()
                fixture.recorder.endSession()
            }
        }

        let counters = try #require(fixture.retention.record)
        #expect(counters.totalSessionsCount == 1)
        #expect(counters.openSessionStartedAt != nil)
    }

    /// A plain reset is a data reset, not a reopen: it erases what the
    /// callback cannot have collected anyway, and leaves the gate shut.
    @Test("A plain reset during the callback erases and leaves collection closed")
    func plainResetDuringTheCallbackLeavesCollectionClosed() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)

        fixture.recorder.resetClosingCollection {
            Self.onAnotherThread {
                fixture.recorder.reset()
                fixture.recorder.record("during")
            }
        }
        fixture.recorder.record("after")
        await fixture.recorder.drain()

        let sent = fixture.transport.sentSignals
        #expect(sent.map(\.name) == ["after"])
        #expect(fixture.retention.record?.totalSessionsCount == 1)
    }

    /// The send claimed before the reset belongs to the erased queue: its
    /// verdict takes nothing off the queue the reopen starts.
    @Test("A send in flight across the reset is discarded, and nothing recorded during it is sent")
    func sendInFlightAcrossTheResetIsDiscarded() async throws {
        let directory = try #require(TestTempDirectory.url)
        let transport = HeldFirstSendTransport()
        defer { transport.release() }
        let storage = RecordingQueueStorage(directory: directory)
        let recorder = try SignalRecorder(
            configuration: testConfiguration(transmitInterval: 3600),
            transport: transport,
            queueStorage: storage,
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
        storage.settle = { [weak recorder] in recorder?.writer.waitForPendingWrites() }
        recorder.updateConsent(.granted)
        recorder.record("before")
        recorder.flush()
        await transport.firstSendHeld.wait()

        let resetDone = Gate()
        DispatchQueue.global().async {
            recorder.resetClosingCollection {
                transport.release()
                // Long enough for the released send's verdict to land.
                Thread.sleep(forTimeInterval: 0.2)
                Self.onAnotherThread { recorder.record("during") }
            }
            resetDone.open()
        }
        await resetDone.wait()
        recorder.record("after")
        await recorder.drain()

        #expect(transport.sentSignalNames == ["before", "after"])
        #expect(storage.signalsOnDisk.isEmpty)
    }

    /// A rotation that fails still ends: a gate the failure left shut would
    /// stop collection for the life of the process.
    @Test("A callback that throws still reopens collection, and the error reaches the caller")
    func throwingCallbackStillReopens() async throws {
        let fixture = try makeFixture()
        fixture.recorder.updateConsent(.granted)

        #expect(throws: RotationFailed.self) {
            try fixture.recorder.resetClosingCollection {
                Self.onAnotherThread { fixture.recorder.record("during") }
                throw RotationFailed()
            }
        }
        fixture.recorder.record("after")
        await fixture.recorder.drain()

        #expect(fixture.transport.sentSignalNames == ["after"])
        #expect(fixture.retention.record?.totalSessionsCount == 1)
    }

    // MARK: Private

    /// What each layer has done so far: payload reads, identifier
    /// resolutions, queue writes, counter saves, and sends.
    private static func layers(_ fixture: RecorderFixture) -> [Int] {
        [
            fixture.environmentCalls.count,
            fixture.clientUserCalls.count,
            fixture.storage.persistCallCount,
            fixture.retention.saved.count,
            fixture.transport.sendCount
        ]
    }

    /// Runs `work` on a GCD thread and returns once it has. The callback is
    /// synchronous, so this blocks; it is a GCD thread doing the work, not the
    /// pool, so nothing the work needs is parked behind the wait.
    private static func onAnotherThread(_ work: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            work()
            done.signal()
        }
        done.wait()
    }

    private func makeFixture() throws -> RecorderFixture {
        let directory = try #require(TestTempDirectory.url)
        return try AethergramCoreTests.makeFixture(
            directory: directory,
            now: steppingClock(from: testDate(year: 2026, month: 3, day: 4))
        )
    }
}

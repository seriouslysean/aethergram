@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// The proof behind `SignalRecorder`'s headline claim: consent is an absolute
/// bar, not a filter.
///
/// A transport-only assertion cannot tell "dropped before enqueue" from
/// "enqueued but not yet sent", and only the first satisfies the requirement.
/// So every arm here asserts at all four layers the recorder touches: the
/// transport, the queue-storage calls, the bytes on disk, and the two provider
/// closures that would otherwise mint an identifier or read a payload.
@Suite("Consent enforcement", .tempDirectory, .tags(.consent))
struct ConsentEnforcementTests {
    /// Three arms, because the pristine one is the strongest: a recorder that
    /// has never been handed an answer must behave exactly like one handed a
    /// decline. `nil` means `updateConsent` is never called at all.
    @Test(
        "Nothing is collected until the answer is granted",
        arguments: [ConsentState?.none, .neverAsked, .declined]
    )
    func nonGrantedConsentCollectsNothing(state: ConsentState?) async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))
        if let state {
            fixture.recorder.updateConsent(state)
        }

        for index in 0 ..< 50 {
            fixture.recorder.record("signal.\(index)")
        }
        fixture.recorder.recordError(id: "boom")
        fixture.recorder.recordPurchaseCompleted(
            PurchaseDetails(
                productID: "p1",
                countryCode: "US",
                currencyCode: "USD",
                isSubscription: false,
                price: 1.99
            )
        )
        await fixture.recorder.drain()

        #expect(fixture.transport.sendCount == 0)
        #expect(fixture.storage.persistCallCount == 0)
        #expect(!fixture.storage.fileExists)
        #expect(fixture.storage.signalsOnDisk.isEmpty)
        #expect(!fixture.clientUserCalls.wasCalled)
        #expect(!fixture.environmentCalls.wasCalled)
    }

    /// Session boundaries are the other write path. A counter that advanced
    /// before the grant would survive as collected data even though nothing
    /// was ever sent.
    @Test("Session boundaries advance no counter before a grant")
    func sessionBoundariesBeforeGrantAdvanceNothing() throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))

        fixture.recorder.beginSession()
        fixture.recorder.endSession()

        #expect(fixture.retention.saved.isEmpty)
        #expect(fixture.retention.record == nil)
        #expect(fixture.retention.loadCallCount == 0)
        #expect(fixture.retention.clearCallCount == 0)
    }

    @Test("A grant delivers exactly what was recorded, in order")
    func grantedConsentDeliversRecordedSignalsInOrder() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))
        let names = ["alpha", "beta", "gamma"]

        fixture.recorder.updateConsent(.granted)
        for name in names {
            fixture.recorder.record(name)
        }
        await fixture.recorder.drain()

        #expect(fixture.transport.sendCount == 1)
        #expect(fixture.transport.sentSignalNames == names)
        let stamps = fixture.transport.sentSignals.map(\.recordedAt)
        #expect(stamps == stamps.sorted())
        #expect(Set(stamps).count == names.count)

        let batch = try #require(fixture.transport.batches.first)
        #expect(batch.clientUser == "client-user")
        #expect(!batch.sessionID.isEmpty)
        #expect(fixture.clientUserCalls.wasCalled)
    }

    /// A toggle that leaves yesterday's signals on disk to be sent later is not
    /// an off switch. The decline must empty the pending set, delete the file,
    /// and clear the retention record.
    @Test("A decline purges the queue, the file, and the counters")
    func declineErasesEverythingCollectedUnderTheGrant() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.beginSession()
        fixture.recorder.record("alpha")
        fixture.recorder.record("beta")
        // Writes coalesce, so a decline arriving before the writer runs
        // supersedes the unwritten snapshot and no file is ever created.
        // The precondition this test needs — signals genuinely on disk —
        // has to be established rather than assumed.
        fixture.recorder.writer.waitForPendingWrites()
        #expect(fixture.storage.fileExists)
        #expect(fixture.storage.signalsOnDisk.count == 2)
        #expect(fixture.retention.record != nil)

        fixture.recorder.updateConsent(.declined)
        fixture.recorder.writer.waitForPendingWrites()

        #expect(!fixture.storage.fileExists)
        #expect(fixture.storage.signalsOnDisk.isEmpty)
        #expect(fixture.retention.clearCallCount == 1)
        #expect(fixture.retention.record == nil)

        await fixture.recorder.drain()
        #expect(fixture.transport.sendCount == 0)
    }

    /// The transmit path re-reads consent rather than trusting the state it was
    /// queued under. Note the second gate inside `sendNextBatch`, the one after
    /// the batch is built, is only reachable against a concurrent decline: a
    /// decline on the same task empties `pending` first, so the drain loop has
    /// nothing left to carry into that check. What is deterministic, and what
    /// this asserts, is that a decline before the drain sends nothing and that
    /// re-granting afterwards resurrects nothing.
    @Test("A decline before the drain sends nothing, and a later grant recovers nothing")
    func declineBeforeDrainStopsTransmissionBeyondRecovery() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        fixture.recorder.record("beta")
        fixture.recorder.updateConsent(.declined)

        await fixture.recorder.drain()
        #expect(fixture.transport.sendCount == 0)

        fixture.recorder.updateConsent(.granted)
        await fixture.recorder.drain()
        #expect(fixture.transport.sendCount == 0)
        #expect(fixture.storage.signalsOnDisk.isEmpty)
    }

    /// The recovery path the file-is-gone assertion cannot reach.
    ///
    /// A real `removeItem` can throw; `FileSignalQueueStorage` logs that and
    /// swallows it, so the recorder gets no signal that the bytes survived. Its
    /// only defence is refusing to re-read the queue after a purge it asked
    /// for, which is what `queueRestored = true` on the non-granted branch buys.
    /// Drop that line and declined-era signals ride out on the next grant.
    @Test("A failed purge cannot resurrect declined-era signals on a later grant")
    func failedPurgeCannotResurrectDeclinedSignals() async throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let storage = PurgeResistantQueueStorage()
        let transport = SpyTransport()
        let recorder = SignalRecorder(
            configuration: testConfiguration(),
            transport: transport,
            queueStorage: storage,
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: start)
        )

        recorder.updateConsent(.granted)
        for name in ["alpha", "beta", "gamma"] {
            recorder.record(name)
        }
        // Forces the snapshot to disk before the purge, so the purge has
        // something to fail at; coalescing would otherwise let the purge
        // supersede the write and there would be nothing to resurrect.
        recorder.writer.waitForPendingWrites()
        recorder.updateConsent(.declined)
        recorder.writer.waitForPendingWrites()

        // The purge was asked for and failed, so the signals are genuinely
        // still there. Without that, the test would prove nothing.
        #expect(storage.purgeCallCount == 1)
        #expect(storage.survivingSignals.count == 3)

        recorder.updateConsent(.granted)
        await recorder.drain()

        #expect(transport.sendCount == 0)
        #expect(transport.sentSignalNames.isEmpty)

        // `enqueue` restores the queue too, so a fresh record under the new
        // grant must carry only itself out.
        recorder.record("fresh")
        await recorder.drain()

        #expect(transport.sentSignalNames == ["fresh"])
    }

    /// `reset()` carries the same no-re-read guard as the decline branch, and a
    /// data reset is the path where a survivor is least excusable: the person
    /// asked for erasure outright rather than merely withdrawing permission.
    @Test("A failed purge cannot resurrect signals after a data reset")
    func failedPurgeCannotResurrectSignalsAfterReset() async throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let storage = PurgeResistantQueueStorage()
        let transport = SpyTransport()
        let recorder = SignalRecorder(
            configuration: testConfiguration(),
            transport: transport,
            queueStorage: storage,
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: steppingClock(from: start)
        )

        recorder.updateConsent(.granted)
        for name in ["alpha", "beta", "gamma"] {
            recorder.record(name)
        }
        recorder.writer.waitForPendingWrites()
        recorder.reset()
        recorder.writer.waitForPendingWrites()

        #expect(storage.purgeCallCount == 1)
        #expect(storage.survivingSignals.count == 3)

        // Consent is untouched by a reset, so the gate is open and only the
        // no-re-read guard stands between the survivors and the transport.
        await recorder.drain()
        #expect(transport.sentSignalNames.isEmpty)

        recorder.record("fresh")
        await recorder.drain()
        #expect(transport.sentSignalNames == ["fresh"])
    }

    /// The SDK this package replaces kept its retention counters somewhere a
    /// data reset could not reach, which is the defect `reset()` exists to
    /// fix. Both the queue file and the retention record must go.
    @Test("reset() purges the queue file and clears the retention record")
    func resetPurgesQueueFileAndRetentionRecord() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.beginSession()
        fixture.recorder.record("alpha")
        fixture.recorder.record("beta")
        // Writes coalesce, so a decline arriving before the writer runs
        // supersedes the unwritten snapshot and no file is ever created.
        // The precondition this test needs — signals genuinely on disk —
        // has to be established rather than assumed.
        fixture.recorder.writer.waitForPendingWrites()
        #expect(fixture.storage.fileExists)
        #expect(fixture.retention.record != nil)

        fixture.recorder.reset()
        fixture.recorder.writer.waitForPendingWrites()

        #expect(!fixture.storage.fileExists)
        #expect(fixture.storage.signalsOnDisk.isEmpty)
        #expect(fixture.retention.record == nil)
        #expect(fixture.retention.clearCallCount == 1)

        await fixture.recorder.drain()
        #expect(fixture.transport.sendCount == 0)
    }
}

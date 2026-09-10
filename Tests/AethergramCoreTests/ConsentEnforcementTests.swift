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
///
/// The time limit is the gate on the erase arms below, which hand work to real
/// threads: one that never comes back has to fail under its own name rather
/// than stall the run until a runner is cancelled.
@Suite("Consent enforcement", .tempDirectory, .timeLimit(.minutes(1)), .tags(.consent))
struct ConsentEnforcementTests {
    /// The two ways everything collected under a grant is dropped. They differ
    /// only in whether the consent answer moves with it, which is exactly why
    /// a gate that reads the answer alone catches one and misses the other.
    enum Erasure: CaseIterable, CustomTestStringConvertible {
        case reset
        case declineThenRegrant

        var testDescription: String {
            switch self {
            case .reset: "reset()"
            case .declineThenRegrant: "decline then regrant"
            }
        }

        func apply(to recorder: SignalRecorder) {
            switch self {
            case .reset:
                recorder.reset()
            case .declineThenRegrant:
                recorder.updateConsent(.declined)
                recorder.updateConsent(.granted)
            }
        }
    }

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
        #expect(batch.signals.allSatisfy { !$0.sessionID.isEmpty })
        // Read from the session that is open, not minted per signal: an
        // identifier unique to every signal groups nothing.
        #expect(Set(batch.signals.map(\.sessionID)).count == 1)
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

    /// A batch in flight when an erase lands indexes a queue that no longer
    /// exists, so its verdict applies to nothing. The consent answer cannot
    /// answer that on its own: `reset()` erases without moving it.
    ///
    /// `apply` removes by count rather than by value: the front of the queue
    /// goes for as much as the batch carried. The erase generation is what
    /// tells a verdict on the erased queue from one on the queue that replaced
    /// it, and without that gate this verdict takes one signal off a queue it
    /// never indexed — the record made after the erase, which was never sent.
    @Test("An outcome for an erased batch cannot drop what replaced it", arguments: Erasure.allCases)
    func outcomeForAnErasedBatchLeavesTheNewQueueAlone(erasure: Erasure) async throws {
        let directory = try #require(TestTempDirectory.url)
        let noon = try testDate(year: 2026, month: 1, day: 5)
        let storage = RecordingQueueStorage(directory: directory)
        let transport = MidSendTransport()
        let recorder = SignalRecorder(
            configuration: testConfiguration(),
            transport: transport,
            queueStorage: storage,
            retentionStore: SpyRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { ["env.key": "env-value"] },
            calendar: testCalendar,
            now: fixedClock(at: noon)
        )
        storage.settle = { [weak recorder] in recorder?.writer.waitForPendingWrites() }

        recorder.updateConsent(.granted)
        recorder.record("alpha")
        transport.duringFirstSend = {
            erasure.apply(to: recorder)
            recorder.record("alpha")
        }
        await recorder.drain()

        let sent = try #require(transport.sentSignals.first)
        #expect(transport.sendCount == 1)
        // The survivor is the record made after the erase, and the fixed clock
        // leaves it matching the batch this verdict was for in everything but
        // the session the erase re-minted. It is what a removal that skips the
        // generation gate drops.
        let onDisk = storage.signalsOnDisk
        #expect(onDisk.count == 1)
        let survivor = try #require(onDisk.first)
        #expect(survivor.name == sent.name)
        #expect(survivor.recordedAt == sent.recordedAt)
        #expect(survivor.sessionID != sent.sessionID)

        // Still deliverable, rather than merely still on disk.
        await recorder.drain()
        #expect(transport.sentSignals == [sent, survivor])
    }

    /// A host need not open a session before it records, so the grant mints
    /// one. Without that the first signals of an install would ride out under
    /// an empty session, which no dashboard can group.
    @Test("A signal recorded before any session boundary carries the one the grant minted")
    func signalRecordedBeforeAnyBeginSessionCarriesTheGrantsSession() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        await fixture.recorder.drain()

        let early = try #require(fixture.transport.sentSignals.first)
        #expect(!early.sessionID.isEmpty)

        // The grant's is a session like any other: the host's first boundary
        // replaces it rather than filling a blank.
        fixture.recorder.beginSession()
        fixture.recorder.record("beta")
        await fixture.recorder.drain()

        let later = try #require(fixture.transport.sentSignals.last)
        #expect(later.sessionID != early.sessionID)
    }

    /// A session is collected under a grant like anything else. Reusing its
    /// identifier after an erase joins what follows to what was erased, which
    /// is the one thing a decline is supposed to have made impossible.
    @Test("An erased session identifier is never reused", arguments: Erasure.allCases)
    func erasedSessionIdentifierIsNotReused(erasure: Erasure) async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        await fixture.recorder.drain()
        let before = try #require(fixture.transport.sentSignals.first).sessionID

        erasure.apply(to: fixture.recorder)
        fixture.recorder.record("beta")
        await fixture.recorder.drain()

        let after = try #require(fixture.transport.sentSignals.last).sessionID
        #expect(!before.isEmpty)
        // A reset leaves the gate open, so the next batch needs a session
        // rather than the empty string the erase left.
        #expect(!after.isEmpty)
        #expect(after != before)
    }

    /// An erase drops what was collected and deletes the durable copies of it.
    /// A `record` between those two — a reset leaves consent granted, so
    /// nothing stops one — belongs to the queue that replaced the erased one,
    /// and the older delete must not reach it: the writer keeps only the newest
    /// intent, and the store only the newest write.
    ///
    /// Holding the purge open is what puts the fresh record inside that window
    /// without timing it. The erase is past its lock section either way by
    /// then; what differs is whether the delete went with it.
    @Test("An erase's delete cannot reach what was recorded after it")
    func eraseDeletesNothingRecordedAfterIt() async throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let storage = GatedQueueStorage()
        let store = SpyRetentionStore()
        let recorder = Self.makeRecorder(storage: storage, retention: store, now: steppingClock(from: start))
        recorder.updateConsent(.granted)
        recorder.beginSession()
        recorder.record("old")

        storage.holdPurge()
        // The reset blocks until the test releases the purge, so it goes to a
        // real thread; the test suspends on the gate rather than parking a
        // cooperative thread the reset's own release would need.
        let resetDone = Gate()
        DispatchQueue.global().async {
            recorder.reset()
            resetDone.open()
        }
        await storage.purgeEntered.wait()
        recorder.beginSession()
        recorder.record("fresh")
        storage.releasePurge()
        await resetDone.wait()

        #expect(storage.signals.map(\.name) == ["fresh"])
        // A counter set is the other durable copy, and the count says which
        // one: a session opened against the erased record would read two.
        let counters = try #require(store.record)
        #expect(counters.totalSessionsCount == 1)
    }

    /// A decline promises the file is gone, not that a delete was requested.
    /// The recorder can be released the instant `updateConsent` returns — an
    /// extension is suspended moments after resigning — and a delete still
    /// sitting on a background queue at that point never happens.
    ///
    /// The purge is held open, so a decline that waits for the delete cannot
    /// return while it is held. Reading the gate after a bounded sleep is what
    /// proving that negative costs; a decline that only asks returns at once
    /// and is open by the time the sleep ends.
    @Test("A decline does not return before the queue file is deleted")
    func declineReturnsOnlyAfterThePurgeHasLanded() async throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let storage = GatedQueueStorage()
        let recorder = Self.makeRecorder(storage: storage, retention: SpyRetentionStore(), now: steppingClock(from: start))
        recorder.updateConsent(.granted)
        recorder.record("alpha")

        storage.holdPurge()
        let declineReturned = Gate()
        DispatchQueue.global().async {
            recorder.updateConsent(.declined)
            declineReturned.open()
        }
        await storage.purgeEntered.wait()
        // A sleep the pool may overrun only lengthens the window the decline
        // had to return in, which a negative check can only be helped by.
        try await Task.sleep(for: .milliseconds(500))
        let returnedWithTheDeletePending = declineReturned.isOpen
        storage.releasePurge()
        await declineReturned.wait()

        #expect(!returnedWithTheDeletePending)
        #expect(storage.isPurged)
        #expect(storage.signals.isEmpty)
    }

    /// A counter written after the erase that was supposed to drop it is a
    /// counter the reset did not reach — the defect `reset()` exists to fix,
    /// reintroduced by timing.
    ///
    /// The save is held open from inside the store, so the erase arrives while
    /// it is in flight. What decides the outcome is whether the recorder's lock
    /// is still held at that moment: a save issued under it blocks the erase
    /// until it lands, and one issued after releasing it does not.
    @Test("A retention save cannot land behind the reset that cleared it")
    func retentionSaveCannotLandAfterAReset() async throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let store = GatedRetentionStore()
        let recorder = Self.makeRecorder(storage: GatedQueueStorage(), retention: store, now: steppingClock(from: start))
        recorder.updateConsent(.granted)

        // Real threads rather than tasks: the halves have to run concurrently,
        // and an unstructured task on a saturated cooperative pool need not.
        let sessionOpened = Gate()
        DispatchQueue.global().async {
            recorder.beginSession()
            sessionOpened.open()
        }
        await store.saveEntered.wait()
        let resetDone = Gate()
        DispatchQueue.global().async {
            recorder.reset()
            resetDone.open()
        }
        // A clear arriving while the save is still held is a clear that save
        // can land behind. Issued under the lock the save holds, it cannot
        // arrive at all, and the bound is what proving that costs.
        try await Task.sleep(for: .milliseconds(500))
        let clearedWithTheSaveInFlight = store.cleared.isOpen
        store.releaseSave()
        await sessionOpened.wait()
        await resetDone.wait()

        // The gate had something to fire on: a save really was in flight.
        #expect(store.saveCallCount == 1)
        #expect(!clearedWithTheSaveInFlight)
        #expect(store.record == nil)
    }

    // MARK: Private

    /// A recorder over doubles the test brings itself, for the arms
    /// `makeFixture` cannot serve: its collaborators are the concrete spies.
    private static func makeRecorder(
        storage: any SignalQueueStorage,
        retention: any RetentionStore,
        now: @escaping @Sendable () -> Date
    ) -> SignalRecorder {
        SignalRecorder(
            configuration: testConfiguration(),
            transport: SpyTransport(),
            queueStorage: storage,
            retentionStore: retention,
            clientUserProvider: { "client-user" },
            environmentProvider: { [:] },
            calendar: testCalendar,
            now: now
        )
    }
}

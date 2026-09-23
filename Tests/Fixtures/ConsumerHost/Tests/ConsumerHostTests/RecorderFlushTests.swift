import Aethergram
import Testing
@testable import ConsumerHostApp
@testable import ConsumerHostExtension

/// How long an expired flush may take to return: the recorder's contract is "promptly".
private let expiryBound: Duration = .seconds(2)

@Suite("the patterns over a real recorder", .timeLimit(.minutes(1)))
struct RecorderFlushTests {
    @Test("an expiry while the transport holds the send ends the flush once, within the bound")
    func heldTransportExpiry() async {
        let transport = HeldTransport()
        defer { transport.release() }
        let recorder = grantedRecorder(transport: transport, store: HeldStore())
        let ends = Counter()
        let flush = ExpiringFlush(end: { ends.increment() }, recorder: recorder)

        #expect(flush.start())
        #expect(await transport.entered.within())
        #expect(ends.value == 0)
        flush.expire()

        #expect(await finishes { await flush.waitForWork() }.within(expiryBound))
        #expect(ends.value == 1)
    }

    @Test("an expiry while the queue store holds the writer ends the flush once, within the bound")
    func heldWriterExpiry() async {
        let store = HeldStore()
        store.hold()
        defer { store.release() }
        let recorder = grantedRecorder(transport: AcceptingTransport(), store: store)
        let ends = Counter()
        let flush = ExpiringFlush(end: { ends.increment() }, recorder: recorder)

        #expect(flush.start())
        #expect(await store.persistEntered.within())
        // The flush waits for the removal write, which queues behind the held one.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ends.value == 0)
        flush.expire()

        #expect(await finishes { await flush.waitForWork() }.within(expiryBound))
        #expect(ends.value == 1)
    }

    @Test("the extension pattern returns within the bound when expiry lands on a held transport")
    func extensionPatternHeldTransport() async {
        let transport = HeldTransport()
        defer { transport.release() }
        let recorder = grantedRecorder(transport: transport, store: HeldStore())
        let activity = Activity()
        let expiries = Counter()
        ExtensionFlush.run(
            reason: "flush", performExpiringActivity: activity.perform,
            expire: { expiries.increment() }, recorder: recorder
        )
        let running = onThread { activity.call(expired: false) }
        #expect(await transport.entered.within())
        #expect(!running.isSet)

        activity.call(expired: true)
        #expect(await running.within(expiryBound))
        #expect(expiries.value == 1)
    }

    @Test("the extension pattern returns within the bound when expiry lands on a held writer")
    func extensionPatternHeldWriter() async {
        let store = HeldStore()
        store.hold()
        defer { store.release() }
        let recorder = grantedRecorder(transport: AcceptingTransport(), store: store)
        let activity = Activity()
        ExtensionFlush.run(reason: "flush", performExpiringActivity: activity.perform, recorder: recorder)
        let running = onThread { activity.call(expired: false) }
        #expect(await store.persistEntered.within())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!running.isSet)

        activity.call(expired: true)
        #expect(await running.within(expiryBound))
    }

    @Test("an extension activity that starts expired never flushes the recorder, and never waits")
    func extensionPatternInitiallyExpired() async {
        let transport = HeldTransport()
        defer { transport.release() }
        let recorder = grantedRecorder(transport: transport, store: HeldStore())
        let started = Flag()
        let activity = Activity()
        ExtensionFlush.run(
            reason: "flush", performExpiringActivity: activity.perform,
            work: {
                started.set()
                await recorder.flushAndWait()
            }
        )
        activity.call(expired: true)
        let returned = onThread { activity.call(expired: false) }

        #expect(await returned.within(expiryBound))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!started.isSet)
        // The recorded signal waits out its coalescing delay rather than being sent.
        #expect(!transport.entered.isSet)
    }

    @Test("the app pattern returns at once over a held transport, and an expiry ends it once")
    @MainActor
    func appPatternHeldTransport() async {
        let transport = HeldTransport()
        defer { transport.release() }
        let recorder = grantedRecorder(transport: transport, store: HeldStore())
        let tasks = BackgroundTasks()
        let flush = AppFlush(beginBackgroundTask: tasks.begin, endBackgroundTask: tasks.end, recorder: recorder)

        flush.start(name: "flush")
        #expect(tasks.begun == ["flush"])
        #expect(tasks.ended.isEmpty)
        #expect(await transport.entered.within())
        #expect(tasks.ended.isEmpty)

        tasks.expirationHandler?()
        #expect(tasks.ended == [7])
        #expect(await finishes { await flush.waitForWork() }.within(expiryBound))
        #expect(tasks.ended == [7])
    }
}

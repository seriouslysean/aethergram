import Dispatch
import Synchronization
import Testing
@testable import ConsumerHostExtension

/// Holds the block `performExpiringActivity` was handed, so a test calls it in any order.
final class Activity: Sendable {
    private let block = Mutex<(@Sendable (Bool) -> Void)?>(nil)

    var perform: ExtensionFlush.PerformExpiringActivity {
        { _, block in self.block.withLock { $0 = block } }
    }

    func call(expired: Bool) {
        let block = block.withLock { $0 }
        block?(expired)
    }
}

@Suite("the extension pattern", .timeLimit(.minutes(1)))
struct ExtensionFlushTests {
    @Test("an expiry landing before the task registers cancels it there, and the call never waits")
    func expiryBeforeRegistration() async {
        let activity = Activity()
        let work = StubWork()
        let begun = Counter()
        ExtensionFlush.run(
            reason: "flush", performExpiringActivity: activity.perform,
            begin: { begun.increment() }, expire: {}, work: { await work.run() },
            beforeRegistration: { activity.call(expired: true) }
        )
        let returned = onThread { activity.call(expired: false) }

        #expect(await returned.within())
        #expect(await work.finished.within())
        #expect(work.wasCancelled)
        #expect(begun.value == 0)
    }

    @Test("an activity that starts expired never starts the work, and never waits")
    func initiallyExpired() async {
        let activity = Activity()
        let work = StubWork()
        let expiries = Counter()
        ExtensionFlush.run(
            reason: "flush", performExpiringActivity: activity.perform,
            expire: { expiries.increment() }, work: { await work.run() }
        )
        activity.call(expired: true)
        let returned = onThread { activity.call(expired: false) }

        #expect(await returned.within())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!work.started.isSet)
        #expect(expiries.value == 1)
    }

    @Test("an expiry while the first call waits cancels the work and releases the wait")
    func expiryConcurrentWithTheRunningCall() async {
        let activity = Activity()
        let work = StubWork()
        let begun = Flag()
        let expiries = Counter()
        ExtensionFlush.run(
            reason: "flush", performExpiringActivity: activity.perform,
            begin: { begun.set() }, expire: { expiries.increment() }, work: { await work.run() }
        )
        let running = onThread { activity.call(expired: false) }
        #expect(await begun.within())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!running.isSet, "the call returned while the work was still running")

        // Twice and concurrently, as the system may.
        let first = onThread { activity.call(expired: true) }
        let second = onThread { activity.call(expired: true) }

        #expect(await running.within())
        #expect(await first.within())
        #expect(await second.within())
        #expect(await work.finished.within())
        #expect(work.wasCancelled)
        #expect(expiries.value == 1)
    }

    @Test("work that finishes before any expiry ends the activity uncancelled")
    func completionWithoutExpiry() async {
        let activity = Activity()
        let work = StubWork()
        ExtensionFlush.run(reason: "flush", performExpiringActivity: activity.perform, work: { await work.run() })
        let running = onThread { activity.call(expired: false) }
        #expect(await work.started.within())
        work.release()

        #expect(await running.within())
        #expect(!work.wasCancelled)
    }

    @Test("end runs exactly once when an expiry races the work finishing")
    func exactlyOnceUnderExpiryRacingCompletion() async {
        for _ in 0..<200 {
            let ends = Counter()
            let work = StubWork()
            let flush = ExpiringFlush(end: { ends.increment() }, work: { await work.run() })
            flush.start()
            #expect(await work.started.within())
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                if index == 0 { work.release() } else { flush.expire() }
            }
            await flush.waitForWork()
            #expect(ends.value == 1)
        }
    }
}

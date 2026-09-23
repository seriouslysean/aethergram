import Testing
@testable import ConsumerHostApp

/// The two UIKit calls, recorded, with the expiration handler kept for the test to fire.
@MainActor
private final class BackgroundTasks {
    var begun: [String] = []
    var ended: [Int] = []
    var expirationHandler: (@MainActor @Sendable () -> Void)?
    /// Fires the handler inside the begin call, as a system with no time left may.
    var expireDuringBegin = false

    var begin: AppFlush<Int>.BeginBackgroundTask {
        { name, handler in
            self.begun.append(name)
            self.expirationHandler = handler
            if self.expireDuringBegin { handler() }
            return 7
        }
    }

    var end: AppFlush<Int>.EndBackgroundTask {
        { self.ended.append($0) }
    }
}

@Suite("the app pattern", .timeLimit(.minutes(1)))
@MainActor
struct AppFlushTests {
    @Test("starting on the main actor returns while the work is still running")
    func startDoesNotBlockTheMainActor() async {
        let tasks = BackgroundTasks()
        let work = StubWork()
        let flush = AppFlush(beginBackgroundTask: tasks.begin, endBackgroundTask: tasks.end, work: { await work.run() })

        flush.start(name: "flush")
        #expect(tasks.begun == ["flush"])
        #expect(tasks.ended.isEmpty)
        // The main actor is free, so the work can start and park while it waits here.
        #expect(await work.started.within())
        #expect(tasks.ended.isEmpty)

        work.release()
        await flush.waitForWork()
        #expect(tasks.ended == [7])
        #expect(!work.wasCancelled)
    }

    @Test("an expiry cancels the work and ends the background task at once, and only once")
    func expiryCancelsAndEnds() async throws {
        let tasks = BackgroundTasks()
        let work = StubWork()
        let flush = AppFlush(beginBackgroundTask: tasks.begin, endBackgroundTask: tasks.end, work: { await work.run() })
        flush.start(name: "flush")
        #expect(await work.started.within())

        tasks.expirationHandler?()
        #expect(tasks.ended == [7])
        // Bounded: work nobody cancelled never finishes, and awaiting its task would hang the run.
        try #require(await work.finished.within(), "the expiry did not cancel the work")
        await flush.waitForWork()
        #expect(work.wasCancelled)
        #expect(tasks.ended == [7])
    }

    @Test("an expiry fired inside the begin call ends the task once and never starts the work")
    func expiryDuringBegin() async {
        let tasks = BackgroundTasks()
        tasks.expireDuringBegin = true
        let work = StubWork()
        let flush = AppFlush(beginBackgroundTask: tasks.begin, endBackgroundTask: tasks.end, work: { await work.run() })

        flush.start(name: "flush")
        await flush.waitForWork()
        #expect(tasks.ended == [7])
        #expect(!work.started.isSet)
    }

    @Test("the background task ends exactly once when an expiry races the work finishing")
    func exactlyOnceUnderExpiryRacingCompletion() async {
        for round in 0..<200 {
            let tasks = BackgroundTasks()
            let work = StubWork()
            let flush = AppFlush(beginBackgroundTask: tasks.begin, endBackgroundTask: tasks.end, work: { await work.run() })
            flush.start(name: "flush")
            #expect(await work.started.within())

            // Either order, and a varying number of hops between, so the task's own end() lands
            // before, between, and after the handler's.
            if round.isMultiple(of: 2) {
                work.release()
                for _ in 0..<(round % 7) { await Task.yield() }
                tasks.expirationHandler?()
            } else {
                tasks.expirationHandler?()
                work.release()
            }
            await flush.waitForWork()
            #expect(tasks.ended == [7])
        }
    }
}

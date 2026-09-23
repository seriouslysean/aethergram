@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// `RetentionCounters` reads no clock and touches no storage, so every counter
/// is pinned to a fixed date here rather than to the machine's.
@Suite("Retention counters")
struct RetentionCountersTests {
    @Test("The first session sets the acquisition day and repeats do not double-count it")
    func sessionStartsCountDistinctDaysOnce() throws {
        let morning = try testDate(year: 2026, month: 1, day: 5, hour: 9)
        let evening = try testDate(year: 2026, month: 1, day: 5, hour: 21)
        let nextDay = try testDate(year: 2026, month: 1, day: 6, hour: 9)

        var record = RetentionCounters.recordingSessionStart(in: nil, at: morning, calendar: testCalendar)
        #expect(record.firstSessionDay == "2026-01-05")
        #expect(record.totalSessionsCount == 1)
        #expect(record.distinctDaysUsed == ["2026-01-05"])

        record = RetentionCounters.recordingSessionStart(in: record, at: evening, calendar: testCalendar)
        #expect(record.totalSessionsCount == 2)
        #expect(record.distinctDaysUsed == ["2026-01-05"])

        record = RetentionCounters.recordingSessionStart(in: record, at: nextDay, calendar: testCalendar)
        #expect(record.totalSessionsCount == 3)
        #expect(record.distinctDaysUsed == ["2026-01-05", "2026-01-06"])
        // The acquisition day is the first one, not the latest.
        #expect(record.firstSessionDay == "2026-01-05")
    }

    /// The window is inclusive at its far edge: the day exactly 30 back counts,
    /// the day 31 back does not.
    @Test("Only days inside the 30-day window reach the last-month counter")
    func lastMonthCounterRespectsTheWindowBoundary() throws {
        let now = try testDate(year: 2026, month: 3, day: 2)
        // Oldest first, so the record's day history reads the way the recorder
        // writes it: most recent last.
        let offsets = [40, 31, RetentionCounters.recentWindowDays, 0]
        let days = try offsets.map { offset in
            let date = try #require(testCalendar.date(byAdding: .day, value: -offset, to: now))
            return RetentionCounters.dayString(for: date, calendar: testCalendar)
        }
        let record = RetentionRecord(
            firstSessionDay: days[0],
            totalSessionsCount: days.count,
            distinctDaysUsed: days
        )

        let parameters = RetentionCounters.parameters(from: record, at: now, calendar: testCalendar)

        #expect(parameters[PayloadKey.retentionDistinctDaysUsed] == "4")
        #expect(parameters[PayloadKey.retentionDistinctDaysUsedLastMonth] == "2")
        #expect(parameters[PayloadKey.acquisitionFirstSessionDate] == days[0])
        #expect(parameters[PayloadKey.retentionTotalSessionsCount] == "4")
    }

    @Test("An absent record contributes no parameters at all")
    func absentRecordEmitsNoParameters() throws {
        let now = try testDate(year: 2026, month: 3, day: 2)
        #expect(RetentionCounters.parameters(from: nil, at: now, calendar: testCalendar).isEmpty)
    }

    /// Sessions close by inference at the next activation, so a duration is
    /// `lastActivityAt - start` rather than anything a shutdown callback
    /// reported. This is the path that has to work, because an app extension is
    /// killed without a callback often enough that the other one frequently
    /// never runs.
    @Test("A session left open by a killed process closes at the next activation")
    func killedSessionClosesAtNextActivation() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        var record = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)
        // Two minutes of use, then the process dies: no end call ever happens.
        record = RetentionCounters.touching(record, at: start.addingTimeInterval(120)).record
        #expect(record.completedSessionsCount == 0)

        let relaunch = start.addingTimeInterval(3600)
        record = RetentionCounters.recordingSessionStart(in: record, at: relaunch, calendar: testCalendar)

        // 120, not 3600: the hour the process spent dead is not use.
        #expect(record.completedSessionsCount == 1)
        #expect(record.totalSessionSeconds == 120)
        #expect(record.previousSessionSeconds == 120)
        #expect(record.totalSessionsCount == 2)
    }

    /// An extension is often killed within seconds of opening. A checkpoint
    /// that waits out the whole interval before its first write leaves such a
    /// session closing at zero seconds, which `folding` discards, so the
    /// average only ever hears about the sessions long enough to survive it.
    @Test("A session killed inside the checkpoint interval still closes with its measured duration")
    func shortKilledSessionIsMeasured() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        var record = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)
        let touch = RetentionCounters.touching(record, at: start.addingTimeInterval(3))
        #expect(touch.shouldPersist, "the first activity after a start is the one a kill would otherwise lose")
        record = touch.record

        record = RetentionCounters.recordingSessionStart(
            in: record,
            at: start.addingTimeInterval(3600),
            calendar: testCalendar
        )

        #expect(record.completedSessionsCount == 1)
        #expect(record.totalSessionSeconds == 3)
        #expect(record.previousSessionSeconds == 3)
    }

    /// The divisor is completed sessions, matching the vendor's `dropLast()`.
    /// Dividing by started sessions is low by `k/(k+1)` forever — half the
    /// truth at one completed session — because the in-flight session
    /// contributes a count but no seconds.
    @Test("The average divides by completed sessions, not started ones", arguments: [1, 20])
    func averageDividesByCompletedSessions(completed: Int) throws {
        let day = try testDate(year: 2026, month: 1, day: 5)
        var record: RetentionRecord?
        var cursor = day
        for _ in 0 ..< completed {
            let opened = RetentionCounters.recordingSessionStart(in: record, at: cursor, calendar: testCalendar)
            record = RetentionCounters.touching(opened, at: cursor.addingTimeInterval(10)).record
            cursor = cursor.addingTimeInterval(600)
        }
        // One more session opened and still in flight, which is the case that
        // used to drag the average down.
        record = RetentionCounters.recordingSessionStart(in: record, at: cursor, calendar: testCalendar)
        let closed = try #require(record)

        #expect(closed.completedSessionsCount == completed)
        #expect(closed.totalSessionsCount == completed + 1)
        let parameters = RetentionCounters.parameters(from: closed, at: cursor, calendar: testCalendar)
        // Every completed session ran exactly ten seconds, so the mean is ten
        // regardless of k — and would read below ten at any k if the in-flight
        // session were in the divisor.
        #expect(parameters[PayloadKey.retentionAverageSessionSeconds] == "10")
    }

    /// `-1`, not `0`, and it is the vendor's sentinel: the dashboard reads that
    /// key by name and a zero cannot be told apart from a genuinely instant
    /// session. The field read zero for every captured signal before this.
    @Test("A first session reports the no-data sentinel and omits the previous one")
    func firstSessionReportsSentinel() throws {
        let day = try testDate(year: 2026, month: 1, day: 5)
        let record = RetentionCounters.recordingSessionStart(in: nil, at: day, calendar: testCalendar)

        let parameters = RetentionCounters.parameters(from: record, at: day, calendar: testCalendar)
        #expect(parameters[PayloadKey.retentionAverageSessionSeconds] == "-1")
        #expect(parameters[PayloadKey.retentionPreviousSessionSeconds] == nil)
    }

    /// A guard against a clock change or a corrupted record, not a timeout
    /// policy: a discarded session is not counted as completed either, so the
    /// divisor cannot be inflated by the sessions it refuses to measure.
    @Test(
        "An impossible or absurd duration is discarded and not counted",
        arguments: [-5.0, 0.0, Double.infinity, Double.nan, 90000.0]
    )
    func impossibleDurationsAreDiscarded(seconds: Double) throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        var record = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)
        record = RetentionCounters.touching(record, at: start.addingTimeInterval(seconds)).record
        record = RetentionCounters.recordingSessionStart(
            in: record,
            at: start.addingTimeInterval(30 * 60 * 60),
            calendar: testCalendar
        )

        #expect(record.completedSessionsCount == 0)
        #expect(record.totalSessionSeconds == 0)
        #expect(record.previousSessionSeconds == nil)
    }

    /// The negative case above routes through `touching`, which refuses to move
    /// the checkpoint backwards, so it only ever proves the zero-length path.
    /// An explicit end is the one caller that hands `folding` a negative
    /// duration directly — a clock set back between start and end.
    @Test("An explicit end before its own start is discarded and not counted")
    func explicitEndBeforeStartIsDiscarded() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let opened = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)

        let closed = RetentionCounters.recordingSessionEnd(in: opened, at: start.addingTimeInterval(-5))

        #expect(closed.completedSessionsCount == 0)
        #expect(closed.totalSessionSeconds == 0)
        #expect(closed.previousSessionSeconds == nil)
        #expect(closed.openSessionStartedAt == nil)
    }

    /// A record whose session has a start but no checkpoint has no measured
    /// end. It is closed so the next session can open, and counted as nothing
    /// rather than as a guess.
    @Test("An open session with no recorded activity closes without being counted")
    func openSessionWithoutActivityClosesUncounted() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let record = RetentionRecord(firstSessionDay: "2026-01-05", totalSessionsCount: 1, openSessionStartedAt: start)

        let closed = RetentionCounters.closingOpenSession(in: record)

        #expect(closed.openSessionStartedAt == nil)
        #expect(closed.completedSessionsCount == 0)
        #expect(closed.totalSessionSeconds == 0)
        #expect(closed.previousSessionSeconds == nil)
    }

    /// The cap is what bounds the record's size; without eviction a daily user
    /// grows it forever. Oldest days go first, and the acquisition day is not
    /// part of the history, so it survives the eviction.
    @Test("The day history keeps only the most recent days past its limit")
    func dayHistoryEvictsOldestPastLimit() throws {
        let first = try testDate(year: 2024, month: 1, day: 1)
        var record: RetentionRecord?
        for offset in 0 ... RetentionCounters.distinctDayLimit {
            let day = try #require(testCalendar.date(byAdding: .day, value: offset, to: first))
            record = RetentionCounters.recordingSessionStart(in: record, at: day, calendar: testCalendar)
        }
        let capped = try #require(record)
        let last = try #require(testCalendar.date(byAdding: .day, value: RetentionCounters.distinctDayLimit, to: first))

        #expect(capped.distinctDaysUsed.count == RetentionCounters.distinctDayLimit)
        #expect(capped.distinctDaysUsed.first == "2024-01-02")
        #expect(capped.distinctDaysUsed.last == RetentionCounters.dayString(for: last, calendar: testCalendar))
        #expect(capped.firstSessionDay == "2024-01-01")
    }

    /// A day turns over at the device's midnight, not UTC's, and the window
    /// is thirty calendar days even across the 23-hour day a spring-forward
    /// makes. 2026-03-08 is that day in New York.
    @Test("Days follow the device's midnight and the window spans a daylight-saving change")
    func dayMathFollowsLocalMidnightAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
        }

        var record: RetentionRecord?
        for date in try [local(2, 5, 23, 30), local(2, 6, 23, 30), local(3, 7, 23, 30), local(3, 8, 23, 30)] {
            record = RetentionCounters.recordingSessionStart(in: record, at: date, calendar: calendar)
        }
        let parameters = RetentionCounters.parameters(from: record, at: try local(3, 8, 23, 45), calendar: calendar)

        // 23:30 in New York is already the next day in UTC.
        #expect(record?.distinctDaysUsed == ["2026-02-05", "2026-02-06", "2026-03-07", "2026-03-08"])
        // 2026-02-06 is exactly thirty days before 2026-03-08; 2026-02-05 is not.
        #expect(parameters[PayloadKey.retentionDistinctDaysUsedLastMonth] == "3")
    }

    /// The deactivation hook is more precise than the checkpoint when it fires,
    /// and it is allowed to fire; it is simply not required to.
    @Test("An explicit end closes the session against its own instant")
    func explicitEndClosesAgainstItsOwnInstant() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        var record = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)
        record = RetentionCounters.touching(record, at: start.addingTimeInterval(10)).record
        record = RetentionCounters.recordingSessionEnd(in: record, at: start.addingTimeInterval(45))

        #expect(record.completedSessionsCount == 1)
        #expect(record.totalSessionSeconds == 45)
        #expect(record.openSessionStartedAt == nil)
    }

    /// The checkpoint is the measurement, and persisting it on every signal
    /// would put a `UserDefaults` write on the emit path. The first activity
    /// after a start is written at once, so a kill cannot erase the session;
    /// every later one waits out the interval.
    @Test("The activity checkpoint writes the first activity, then only once past the interval")
    func checkpointCoalescesWrites() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let opened = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)

        #expect(!RetentionCounters.touching(opened, at: start).shouldPersist, "no time has passed")
        let first = RetentionCounters.touching(opened, at: start.addingTimeInterval(1))
        #expect(first.shouldPersist)
        #expect(!RetentionCounters.touching(first.record, at: start.addingTimeInterval(2)).shouldPersist)
        #expect(RetentionCounters.touching(first.record, at: start.addingTimeInterval(11)).shouldPersist)
    }

    /// `lastActivityAt` must only advance when the interval
    /// genuinely elapsed, or the comparison baseline slides forward on every
    /// non-persisting touch and activity more frequent than the interval
    /// never crosses it -- four touches 3s apart span 11 real seconds but
    /// each individual gap is only 3s, which the prior (always-advance)
    /// shape would measure forever and never checkpoint.
    @Test("Sub-interval activity still checkpoints once true elapsed time crosses the interval")
    func subIntervalActivityEventuallyCheckpoints() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let opened = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)
        var record = RetentionCounters.touching(opened, at: start.addingTimeInterval(1)).record

        for offset in [4, 7, 10] {
            let touch = RetentionCounters.touching(record, at: start.addingTimeInterval(Double(offset)))
            #expect(!touch.shouldPersist, "offset \(offset)s must not cross the 10s interval yet")
            record = touch.record
        }
        let final = RetentionCounters.touching(record, at: start.addingTimeInterval(12))
        #expect(final.shouldPersist, "11 real seconds since the last checkpoint must cross the interval")
    }

    /// A corrupt or hostile record must not crash its host. Without the
    /// saturating increment this traps on the record's `totalSessionsCount
    /// += 1`.
    @Test("A totalSessionsCount already at Int.max does not trap the next session start")
    func sessionStartDoesNotTrapAtCountLimit() throws {
        let day = try testDate(year: 2026, month: 1, day: 5)
        let record = RetentionRecord(firstSessionDay: "2026-01-05", totalSessionsCount: .max)

        let updated = RetentionCounters.recordingSessionStart(in: record, at: day, calendar: testCalendar)

        #expect(updated.totalSessionsCount == .max)
    }

    /// A corrupt or hostile record must not crash its host. Without the
    /// saturating increment this traps on `folding`'s `completedSessionsCount
    /// += 1`.
    @Test("A completedSessionsCount already at Int.max does not trap the next session end")
    func sessionEndDoesNotTrapAtCountLimit() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let record = RetentionRecord(
            firstSessionDay: "2026-01-05",
            completedSessionsCount: .max,
            openSessionStartedAt: start
        )

        let updated = RetentionCounters.recordingSessionEnd(in: record, at: start.addingTimeInterval(30))

        #expect(updated.completedSessionsCount == .max)
    }

    /// A corrupt or hostile record must not crash its host. Without the
    /// range check this traps `Int(...)` in `averageSessionSeconds` once the
    /// division exceeds what `Int` can hold.
    @Test("An average seconds value wider than Int reports the no-data sentinel instead of trapping")
    func averageWiderThanIntReportsSentinel() throws {
        let day = try testDate(year: 2026, month: 1, day: 5)
        let record = RetentionRecord(
            firstSessionDay: "2026-01-05",
            completedSessionsCount: 1,
            totalSessionSeconds: 1e308
        )

        let parameters = RetentionCounters.parameters(from: record, at: day, calendar: testCalendar)

        #expect(parameters[PayloadKey.retentionAverageSessionSeconds] == "\(RetentionCounters.noCompletedSessions)")
    }

    /// A corrupt or hostile record must not crash its host. Without the range
    /// check this traps the same `Int(...)` conversion as
    /// `averageSessionSeconds`, on `previousSessionSeconds` instead.
    @Test("A previousSessionSeconds value wider than Int omits the key instead of trapping")
    func previousSessionSecondsWiderThanIntOmitsKey() throws {
        let day = try testDate(year: 2026, month: 1, day: 5)
        let record = RetentionRecord(firstSessionDay: "2026-01-05", previousSessionSeconds: 1e308)

        let parameters = RetentionCounters.parameters(from: record, at: day, calendar: testCalendar)

        #expect(parameters[PayloadKey.retentionPreviousSessionSeconds] == nil)
    }
}

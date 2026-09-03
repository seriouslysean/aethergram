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
    /// would put a `UserDefaults` write on the emit path.
    @Test("The activity checkpoint asks for a write only once past the interval")
    func checkpointCoalescesWrites() throws {
        let start = try testDate(year: 2026, month: 1, day: 5)
        let record = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)

        #expect(!RetentionCounters.touching(record, at: start.addingTimeInterval(1)).shouldPersist)
        #expect(RetentionCounters.touching(record, at: start.addingTimeInterval(10)).shouldPersist)
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
        var record = RetentionCounters.recordingSessionStart(in: nil, at: start, calendar: testCalendar)

        for offset in [3, 6, 9] {
            let touch = RetentionCounters.touching(record, at: start.addingTimeInterval(Double(offset)))
            #expect(!touch.shouldPersist, "offset \(offset)s must not cross the 10s interval yet")
            record = touch.record
        }
        let final = RetentionCounters.touching(record, at: start.addingTimeInterval(11))
        #expect(final.shouldPersist, "11 real seconds since the last checkpoint must cross the interval")
    }
}

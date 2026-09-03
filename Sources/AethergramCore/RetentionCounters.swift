import Foundation

/// The persisted state behind the acquisition and retention counters.
///
/// Held by the host's own storage rather than a package-private suite, and
/// that placement is the whole point: the SDK this package replaces kept its
/// counters somewhere a data reset could not reach, so a user who erased their
/// data kept a retention history. `RetentionStore.clear()` is the fix, and
/// `reset()` on the recorder is what calls it.
public struct RetentionRecord: Codable, Equatable, Sendable {
    // MARK: Lifecycle

    public init(
        firstSessionDay: String,
        totalSessionsCount: Int = 0,
        completedSessionsCount: Int = 0,
        distinctDaysUsed: [String] = [],
        totalSessionSeconds: Double = 0,
        previousSessionSeconds: Double? = nil,
        openSessionStartedAt: Date? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.firstSessionDay = firstSessionDay
        self.totalSessionsCount = totalSessionsCount
        self.completedSessionsCount = completedSessionsCount
        self.distinctDaysUsed = distinctDaysUsed
        self.totalSessionSeconds = totalSessionSeconds
        self.previousSessionSeconds = previousSessionSeconds
        self.openSessionStartedAt = openSessionStartedAt
        self.lastActivityAt = lastActivityAt
    }

    /// Tolerant of a record written before the session fields existed: every
    /// new key decodes to its default rather than failing the whole record and
    /// costing an install its acquisition date and day history.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstSessionDay = try container.decode(String.self, forKey: .firstSessionDay)
        totalSessionsCount = try container.decodeIfPresent(Int.self, forKey: .totalSessionsCount) ?? 0
        completedSessionsCount = try container.decodeIfPresent(Int.self, forKey: .completedSessionsCount) ?? 0
        distinctDaysUsed = try container.decodeIfPresent([String].self, forKey: .distinctDaysUsed) ?? []
        totalSessionSeconds = try container.decodeIfPresent(Double.self, forKey: .totalSessionSeconds) ?? 0
        previousSessionSeconds = try container.decodeIfPresent(Double.self, forKey: .previousSessionSeconds)
        openSessionStartedAt = try container.decodeIfPresent(Date.self, forKey: .openSessionStartedAt)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
    }

    // MARK: Public

    /// `yyyy-MM-dd` in the device's calendar. A day, never a timestamp: the
    /// question a cohort chart asks is which day someone arrived.
    public let firstSessionDay: String
    /// Sessions opened. Includes the one in flight, which is why it cannot be
    /// the divisor for an average of finished sessions.
    public var totalSessionsCount: Int
    /// Sessions closed. The divisor, matching the vendor's `dropLast()`: an
    /// average over started sessions is low by `k/(k+1)` forever — half the
    /// truth at one session — because the in-flight one contributes a count
    /// but no seconds.
    public var completedSessionsCount: Int
    /// `yyyy-MM-dd` entries, most recent last, capped at
    /// `RetentionCounters.distinctDayLimit`.
    public var distinctDaysUsed: [String]
    public var totalSessionSeconds: Double
    public var previousSessionSeconds: Double?
    /// Start of the session currently open, persisted so the next activation
    /// can close it. An app extension is killed without a callback often
    /// enough that a session which only ends at shutdown never ends at all.
    public var openSessionStartedAt: Date?
    /// When that session last recorded a signal. Sessions close by inference
    /// against this rather than against the clock at close time, so an
    /// extension left open behind a locked screen reports the time it was used
    /// rather than the time it sat there.
    public var lastActivityAt: Date?
}

/// Where the retention record lives. The consumer backs this with storage its
/// own data reset already clears.
public protocol RetentionStore: Sendable {
    func load() -> RetentionRecord?
    func save(_ record: RetentionRecord)
    func clear()
}

/// Pure functions over `RetentionRecord`: session boundaries in, counters out.
///
/// Nothing here reads a clock or touches storage, so every counter is testable
/// against a fixed date. Internal: the recorder is the only caller, and a
/// consumer that reached in here would be counting sessions itself.
enum RetentionCounters {
    // MARK: Internal

    /// Distinct-day history is unbounded in principle and a payload field in
    /// practice. 400 days covers the trailing-year cohort questions anyone asks
    /// and bounds the record at a few kilobytes.
    static let distinctDayLimit = 400

    /// The window `distinctDaysUsedLastMonth` reports over.
    static let recentWindowDays = 30

    /// Upper bound on an inferred session, as a guard against a clock change or
    /// a corrupted record — not a session-timeout policy. The vendor's own
    /// five-minute constant is an inactivity threshold for rotating a session
    /// id, not a maximum duration, so using it here would truncate genuine
    /// longer sessions. A day is far past any real extension cycle and still
    /// catches an absurd value.
    static let maximumSessionSeconds: Double = 24 * 60 * 60

    /// How far `lastActivityAt` must move before the record is written again.
    ///
    /// The checkpoint is what makes a session closable after a kill, so it has
    /// to be persisted, but persisting on every signal would put a
    /// `UserDefaults` write on the emit path. Ten seconds bounds the write rate
    /// and bounds the measurement error: a killed session is under-reported by
    /// at most this much. The vendor's one-second timer is more precise and
    /// costs a timer that never fires correctly in this host.
    static let activityCheckpointInterval: Double = 10

    /// The no-data sentinel for `averageSessionSeconds`.
    ///
    /// Matches the vendor's `-1`, which the dashboard already reads as "no
    /// data" by name. Zero is the wrong answer: the field read zero for every
    /// captured signal before this change, and a chart cannot tell an
    /// unmeasured session from a genuinely instant one.
    static let noCompletedSessions = -1

    /// Advances the record for a session that just began. Creates it on the
    /// first session, which is what makes `firstSessionDay` an acquisition date
    /// rather than a guess.
    static func recordingSessionStart(
        in record: RetentionRecord?,
        at date: Date,
        calendar: Calendar
    ) -> RetentionRecord {
        let day = dayString(for: date, calendar: calendar)
        // Any session still open belongs to a process that is gone. Close it
        // first, against its own last activity rather than against now, so the
        // gap between that kill and this activation is not counted as use.
        var updated = closingOpenSession(in: record ?? RetentionRecord(firstSessionDay: day))
        updated.totalSessionsCount += 1
        updated.openSessionStartedAt = date
        updated.lastActivityAt = date
        if !updated.distinctDaysUsed.contains(day) {
            updated.distinctDaysUsed.append(day)
            if updated.distinctDaysUsed.count > distinctDayLimit {
                updated.distinctDaysUsed.removeFirst(updated.distinctDaysUsed.count - distinctDayLimit)
            }
        }
        return updated
    }

    /// Closes the open session against an explicit end instant.
    ///
    /// The consumer's deactivation hook calls this when it fires, which is more
    /// precise than the checkpoint the next activation would otherwise infer
    /// from. It is an optimisation, not a requirement: `recordingSessionStart`
    /// produces a correct duration without it.
    static func recordingSessionEnd(
        in record: RetentionRecord,
        at date: Date
    ) -> RetentionRecord {
        guard let started = record.openSessionStartedAt else { return record }
        return folding(date.timeIntervalSince(started), into: record)
    }

    /// Advances the activity checkpoint, and says whether the record is now
    /// worth persisting. Sessions are closed against this, so it is the
    /// measurement; the interval is what keeps it off the emit path's budget.
    ///
    /// Only advances `lastActivityAt` when the interval has genuinely
    /// elapsed: advancing it on every call would slide the comparison
    /// baseline forward on each touch, so activity more frequent than
    /// `activityCheckpointInterval` would never cross it.
    static func touching(
        _ record: RetentionRecord,
        at date: Date
    ) -> (record: RetentionRecord, shouldPersist: Bool) {
        guard record.openSessionStartedAt != nil else { return (record, false) }
        let moved = date.timeIntervalSince(record.lastActivityAt ?? date)
        guard moved >= activityCheckpointInterval else { return (record, false) }
        var updated = record
        updated.lastActivityAt = date
        return (updated, true)
    }

    /// Closes a session left open by a process that died, using its last
    /// recorded activity as the end.
    static func closingOpenSession(in record: RetentionRecord) -> RetentionRecord {
        guard let started = record.openSessionStartedAt else { return record }
        guard let lastActivity = record.lastActivityAt else {
            var cleared = record
            cleared.openSessionStartedAt = nil
            return cleared
        }
        return folding(lastActivity.timeIntervalSince(started), into: record)
    }

    /// The counters as payload parameters, under canonical package keys. An
    /// adapter maps these onto whatever its vendor calls them.
    static func parameters(
        from record: RetentionRecord?,
        at date: Date,
        calendar: Calendar
    ) -> [String: String] {
        guard let record else { return [:] }
        var parameters: [String: String] = [
            PayloadKey.acquisitionFirstSessionDate: record.firstSessionDay,
            PayloadKey.retentionTotalSessionsCount: "\(record.totalSessionsCount)",
            PayloadKey.retentionDistinctDaysUsed: "\(record.distinctDaysUsed.count)",
            PayloadKey
                .retentionDistinctDaysUsedLastMonth: "\(recentDayCount(in: record, at: date, calendar: calendar))",
            PayloadKey.retentionAverageSessionSeconds: "\(averageSessionSeconds(in: record))"
        ]
        if let previous = record.previousSessionSeconds {
            parameters[PayloadKey.retentionPreviousSessionSeconds] = "\(Int(previous.rounded()))"
        }
        return parameters
    }

    static func dayString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: Private

    /// Folds a duration in and counts the session as completed. A negative,
    /// non-finite, or absurd duration is discarded rather than averaged — a
    /// clock change must not poison the mean — and a discarded session is not
    /// counted as completed either, so the divisor stays honest.
    private static func folding(_ seconds: Double, into record: RetentionRecord) -> RetentionRecord {
        var updated = record
        updated.openSessionStartedAt = nil
        updated.lastActivityAt = nil
        guard seconds > 0, seconds.isFinite, seconds <= maximumSessionSeconds else { return updated }
        updated.totalSessionSeconds += seconds
        updated.previousSessionSeconds = seconds
        updated.completedSessionsCount += 1
        return updated
    }

    /// Averaged over sessions that finished. `-1` when none have.
    private static func averageSessionSeconds(in record: RetentionRecord) -> Int {
        guard record.completedSessionsCount > 0 else { return noCompletedSessions }
        return Int((record.totalSessionSeconds / Double(record.completedSessionsCount)).rounded())
    }

    private static func recentDayCount(in record: RetentionRecord, at date: Date, calendar: Calendar) -> Int {
        guard let cutoff = calendar.date(byAdding: .day, value: -recentWindowDays, to: date) else {
            return record.distinctDaysUsed.count
        }
        let cutoffDay = dayString(for: cutoff, calendar: calendar)
        return record.distinctDaysUsed.count { $0 >= cutoffDay }
    }
}

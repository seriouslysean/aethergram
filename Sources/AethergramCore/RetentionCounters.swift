import Foundation

/// The persisted state behind the acquisition and retention counters.
///
/// Held by the host's own storage rather than a package-private suite, and
/// that placement is the whole point: the SDK this package replaces kept its
/// counters somewhere a data reset could not reach, so a user who erased their
/// data kept a retention history. `RetentionStore.clear()` is the fix, and
/// the recorder calls it on `reset()` and on every non-granted
/// `updateConsent`.
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

    /// `yyyy-MM-dd` in the Gregorian calendar, on the device's clock, except
    /// a day stored before 0.3.2 that the recorder could not convert, which
    /// is kept as written. A day, never a timestamp: the question a cohort
    /// chart asks is which day someone arrived.
    public let firstSessionDay: String
    /// Sessions opened. Includes the one in flight, which is why it cannot be
    /// the divisor for an average of finished sessions.
    public var totalSessionsCount: Int
    /// Sessions closed. The divisor, matching the vendor's `dropLast()`: an
    /// average over started sessions is low by `k/(k+1)` forever — half the
    /// truth at one session — because the in-flight one contributes a count
    /// but no seconds.
    public var completedSessionsCount: Int
    /// Gregorian `yyyy-MM-dd` entries, most recent last, capped at the 400
    /// most recent. An entry stored before 0.3.2 that the recorder could not
    /// convert is kept as written.
    public var distinctDaysUsed: [String]
    /// Seconds summed over completed sessions. A session whose measured
    /// duration is not positive, not finite, or over a day adds nothing and
    /// is not counted as completed.
    public var totalSessionSeconds: Double
    /// The duration of the last completed session, or nil before the first.
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
///
/// Every call here is made under the recorder's non-recursive lock, on the
/// thread of the call that needed it, so a conformance must not call back
/// into the recorder: doing so fails a precondition and terminates the
/// process.
public protocol RetentionStore: Sendable {
    /// The record last saved, or nil when there is none. Read at most once
    /// per recorder between erases.
    func load() -> RetentionRecord?

    /// Replaces the stored record wholesale.
    func save(_ record: RetentionRecord)

    /// Removes the stored record. Called on `reset()` and on every
    /// non-granted `updateConsent`; after it returns, `load()` returns nil.
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
    /// — one write per interval, plus one for a session's first activity — and
    /// bounds the measurement error: a killed session is under-reported by at
    /// most this much, and one with any activity after its start still closes
    /// with a positive duration. The vendor's one-second timer is more precise
    /// and costs a timer that never fires correctly in this host.
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
        updated.totalSessionsCount = saturatingIncrement(updated.totalSessionsCount)
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
    /// `activityCheckpointInterval` would never cross it. The first activity
    /// after a start is the exception, because a session killed before the
    /// interval would otherwise close at zero seconds and be discarded.
    static func touching(
        _ record: RetentionRecord,
        at date: Date
    ) -> (record: RetentionRecord, shouldPersist: Bool) {
        guard let started = record.openSessionStartedAt else { return (record, false) }
        let baseline = record.lastActivityAt ?? started
        let moved = date.timeIntervalSince(baseline)
        let isFirstActivity = baseline == started
        guard moved > 0, isFirstActivity || moved >= activityCheckpointInterval else { return (record, false) }
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
        // Same trap as `averageSessionSeconds`, and the same fix: a corrupt or
        // hostile total must not crash its host. There is no sentinel for a
        // single session's duration, so an unconvertible value omits the key
        // instead of reporting one.
        if let previous = record.previousSessionSeconds, let rounded = Int(exactly: previous.rounded()) {
            parameters[PayloadKey.retentionPreviousSessionSeconds] = "\(rounded)"
        }
        return parameters
    }

    /// Gregorian whatever `calendar` is, on `calendar`'s clock. The string is
    /// a wire field and a sort key: a Buddhist year is 543 ahead, and a
    /// Japanese year restarts at each era, so numbering in the device's
    /// calendar sent a wrong date and sorted a new era before the old one.
    static func dayString(for date: Date, calendar: Calendar) -> String {
        let components = dayCalendar(matching: calendar).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The record with each day string it can place in Gregorian numbering,
    /// decided string by string so that converting twice changes nothing.
    ///
    /// Releases before 0.3.2 wrote the device's own calendar, and nothing in
    /// a record says which numbering it holds: 0.3.1 saves only the keys it
    /// knows, and a host may rebuild the record through the initializer. A
    /// string that reads as a Gregorian day in the window is kept. Any other
    /// is read in `calendar`, on the assumption that the device has not
    /// switched calendars since writing it, and kept converted only if that
    /// reading lands in the window. Anything else is kept as written rather
    /// than guessed at. Converted days keep their order and lose duplicates.
    ///
    /// An Ethiopic year, counted from the incarnation, falls inside the
    /// Gregorian window, so a day written in that numbering is taken as
    /// Gregorian and kept. A Chinese or Dangi day in a leap month was written
    /// without its leap flag, so it is read as the ordinary month of that
    /// number, the one before it, and converts a lunar month early.
    static func convertingDaysToGregorian(
        in record: RetentionRecord,
        at date: Date,
        calendar: Calendar
    ) -> RetentionRecord {
        guard calendar.identifier != .gregorian else { return record }
        let gregorian = dayCalendar(matching: calendar)
        let window = DayWindow(at: date, gregorian: gregorian)
        let convert = { (day: String) in
            guard !window.contains(day) else { return day }
            return gregorianDay(fromLegacy: day, at: date, calendar: calendar, gregorian: gregorian, window: window)
                ?? day
        }
        var converted = RetentionRecord(
            firstSessionDay: convert(record.firstSessionDay),
            totalSessionsCount: record.totalSessionsCount,
            completedSessionsCount: record.completedSessionsCount,
            distinctDaysUsed: record.distinctDaysUsed.map(convert),
            totalSessionSeconds: record.totalSessionSeconds,
            previousSessionSeconds: record.previousSessionSeconds,
            openSessionStartedAt: record.openSessionStartedAt,
            lastActivityAt: record.lastActivityAt
        )
        var seen: Set<String> = []
        converted.distinctDaysUsed.removeAll { !seen.insert($0).inserted }
        return converted
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
        updated.completedSessionsCount = saturatingIncrement(updated.completedSessionsCount)
        return updated
    }

    /// Saturates at `Int.max` instead of trapping. A corrupt or hostile
    /// record must not crash its host over a counter already at the limit.
    private static func saturatingIncrement(_ value: Int) -> Int {
        min(value, Int.max - 1) + 1
    }

    /// Averaged over sessions that finished. `-1` when none have, and also
    /// when a corrupt or hostile total makes the average non-finite or wider
    /// than `Int` — `Int(exactly:)` reports that instead of trapping.
    private static func averageSessionSeconds(in record: RetentionRecord) -> Int {
        guard record.completedSessionsCount > 0 else { return noCompletedSessions }
        let average = (record.totalSessionSeconds / Double(record.completedSessionsCount)).rounded()
        return Int(exactly: average) ?? noCompletedSessions
    }

    /// Bounded above as well as below: a day string no reading could place
    /// is kept as written, and a far-future year or a non-date sorts after
    /// every cutoff.
    private static func recentDayCount(in record: RetentionRecord, at date: Date, calendar: Calendar) -> Int {
        let gregorian = dayCalendar(matching: calendar)
        let window = DayWindow(at: date, gregorian: gregorian)
        guard let cutoff = gregorian.date(byAdding: .day, value: -recentWindowDays, to: date) else {
            return record.distinctDaysUsed.count { window.contains($0) }
        }
        let cutoffDay = dayString(for: cutoff, calendar: gregorian)
        return record.distinctDaysUsed.count { window.contains($0) && $0 >= cutoffDay }
    }

    /// The calendar day strings are numbered in: Gregorian, on the caller's
    /// time zone, so a day still turns over at the device's midnight.
    private static func dayCalendar(matching calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// The Gregorian day a string in `calendar`'s numbering named, or nil when
    /// it names none inside `window`.
    ///
    /// The string carries no era, so it is read in the era current at `date`,
    /// and in the one before when that lands outside the window: a Japanese
    /// year written before an era change would otherwise be read decades
    /// ahead. Read at noon, which no time-zone transition skips.
    private static func gregorianDay(
        fromLegacy day: String,
        at date: Date,
        calendar: Calendar,
        gregorian: Calendar,
        window: DayWindow
    ) -> String? {
        let fields = day.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        let currentEra = calendar.component(.era, from: date)
        for era in [currentEra, currentEra - 1] {
            let components = DateComponents(era: era, year: fields[0], month: fields[1], day: fields[2], hour: 12)
            guard let resolved = calendar.date(from: components) else { continue }
            // `date(from:)` rolls an out-of-range field into the next unit
            // rather than failing, so a string that names no day is caught by
            // reading the day back.
            let check = calendar.dateComponents([.era, .year, .month, .day], from: resolved)
            guard check.era == era, check.year == fields[0], check.month == fields[1], check.day == fields[2] else {
                continue
            }
            let converted = dayString(for: resolved, calendar: gregorian)
            guard window.contains(converted) else { continue }
            return converted
        }
        return nil
    }
}

/// The Gregorian days a stored day string can name: from 2015-01-01, before
/// anything this package wrote, through tomorrow on the caller's clock.
///
/// Also what tells the numberings apart. A Buddhist, Hebrew, or Ethiopic
/// amete-alem year reads as Gregorian after it, and an Islamic, Persian,
/// Coptic, or Japanese year before it, so a string inside it needs no calendar
/// work to be taken as Gregorian.
private struct DayWindow {
    // MARK: Lifecycle

    init(at date: Date, gregorian: Calendar) {
        let tomorrow = gregorian.date(byAdding: .day, value: 1, to: date) ?? date
        latest = RetentionCounters.dayString(for: tomorrow, calendar: gregorian)
    }

    // MARK: Internal

    /// Compared as strings: for a well-formed `yyyy-MM-dd`, string order is
    /// day order.
    func contains(_ day: String) -> Bool {
        Self.isWellFormed(day) && day >= Self.earliest && day <= latest
    }

    // MARK: Private

    private static let earliest = "2015-01-01"

    private let latest: String

    /// Four digits, a dash, a month 01-12, a dash, a day 01-31.
    private static func isWellFormed(_ day: String) -> Bool {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else { return false }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard number(0 ..< 4) != nil, let month = number(5 ..< 7), let day = number(8 ..< 10) else { return false }
        return (1 ... 12).contains(month) && (1 ... 31).contains(day)
    }
}

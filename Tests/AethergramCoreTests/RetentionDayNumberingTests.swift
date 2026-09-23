@testable import AethergramCore
import AethergramTestSupport
import Foundation
import Testing

/// Day strings are a wire field and a sort key, so they are Gregorian
/// whatever calendar the device reads in.
///
/// A device on the Buddhist calendar sent `acquisition.firstSessionDate` as
/// `2569-09-23`, and the Japanese calendar restarts its year at an era change,
/// so a string comparison across one put the new era's days before the old
/// era's. Records written that way are converted once, in the calendar that
/// wrote them, and never again.
@Suite("Retention day numbering", .tags(.persistence))
struct RetentionDayNumberingTests {
    // MARK: Internal

    static let calendars: [Calendar.Identifier] = [
        .gregorian, .buddhist, .japanese, .hebrew, .islamicUmmAlQura, .persian
    ]

    /// Calendars whose year numbers, read as Gregorian, fall outside the
    /// window a day string can name.
    static let convertingCalendars: [Calendar.Identifier] = [
        .buddhist, .japanese, .hebrew, .islamicUmmAlQura, .persian, .coptic, .ethiopicAmeteAlem
    ]

    @Test("A session day is written in Gregorian numbering whatever the device's calendar", arguments: calendars)
    func sessionDayIsGregorian(identifier: Calendar.Identifier) throws {
        let calendar = Self.calendar(identifier)
        let date = try testDate(year: 2026, month: 9, day: 23)

        let record = RetentionCounters.recordingSessionStart(in: nil, at: date, calendar: calendar)
        let parameters = RetentionCounters.parameters(from: record, at: date, calendar: calendar)

        #expect(record.firstSessionDay == "2026-09-23")
        #expect(record.distinctDaysUsed == ["2026-09-23"])
        #expect(parameters[PayloadKey.acquisitionFirstSessionDate] == "2026-09-23")
        #expect(parameters[PayloadKey.retentionDistinctDaysUsedLastMonth] == "1")
    }

    /// Heisei 31 ended on 2019-04-30 and Reiwa 1 began the next day. Compared
    /// as strings in era numbering, `0001-05-01` sorts before a Heisei cutoff,
    /// so every day after the change fell out of the window.
    @Test("The last-month window counts every day across a Japanese era change")
    func recentWindowSpansJapaneseEraChange() throws {
        let calendar = Self.calendar(.japanese)
        var record: RetentionRecord?
        for (month, day) in [(4, 20), (4, 25), (4, 30), (5, 1), (5, 5)] {
            let date = try testDate(year: 2019, month: month, day: day)
            record = RetentionCounters.recordingSessionStart(in: record, at: date, calendar: calendar)
        }
        let now = try testDate(year: 2019, month: 5, day: 10)

        let parameters = RetentionCounters.parameters(from: record, at: now, calendar: calendar)

        #expect(parameters[PayloadKey.retentionDistinctDaysUsedLastMonth] == "5")
        #expect(parameters[PayloadKey.acquisitionFirstSessionDate] == "2019-04-20")
    }

    /// Converted exactly once: a Gregorian 2026 re-read as Buddhist is 1483,
    /// so a record that forgot it was converted would lose five centuries on
    /// every load. The encode and decode between the two sessions is the
    /// point — the conversion has to survive the host's storage.
    @Test("A record written in Buddhist numbering converts once and stays converted across storage")
    func legacyBuddhistRecordConvertsOnce() throws {
        let calendar = Self.calendar(.buddhist)
        let legacy = try Self.decodeLegacy(firstSessionDay: "2569-09-01", distinctDaysUsed: ["2569-09-01", "2569-09-23"])

        let today = try testDate(year: 2026, month: 9, day: 23)
        let converted = RetentionCounters.recordingSessionStart(in: legacy, at: today, calendar: calendar)
        #expect(converted.firstSessionDay == "2026-09-01")
        // Today was already in the legacy history, so it is not appended twice.
        #expect(converted.distinctDaysUsed == ["2026-09-01", "2026-09-23"])

        let stored = try JSONDecoder().decode(RetentionRecord.self, from: JSONEncoder().encode(converted))
        let tomorrow = try testDate(year: 2026, month: 9, day: 24)
        let reloaded = RetentionCounters.recordingSessionStart(in: stored, at: tomorrow, calendar: calendar)

        #expect(reloaded.firstSessionDay == "2026-09-01")
        #expect(reloaded.distinctDaysUsed == ["2026-09-01", "2026-09-23", "2026-09-24"])
    }

    /// The recorder emits parameters from the loaded record before any session
    /// start rewrites it, so the payload must not wait for the rewrite.
    @Test("A record written in Buddhist numbering reports Gregorian days before its next session")
    func legacyBuddhistRecordReportsGregorianDays() throws {
        let calendar = Self.calendar(.buddhist)
        let legacy = try Self.decodeLegacy(firstSessionDay: "2569-06-01", distinctDaysUsed: ["2569-06-01", "2569-09-20"])
        let today = try testDate(year: 2026, month: 9, day: 23)

        let parameters = RetentionCounters.parameters(from: legacy, at: today, calendar: calendar)

        #expect(parameters[PayloadKey.acquisitionFirstSessionDate] == "2026-06-01")
        #expect(parameters[PayloadKey.retentionDistinctDaysUsedLastMonth] == "1")
    }

    /// Each calendar's own numbering, produced the way the old formatter
    /// produced it, reads back as the Gregorian day it named. The Japanese
    /// case includes a Heisei day, which carries no era in its string.
    @Test("A record written in any calendar's numbering converts to the Gregorian day it named", arguments: calendars)
    func legacyRecordConvertsInItsOwnCalendar(identifier: Calendar.Identifier) throws {
        let calendar = Self.calendar(identifier)
        let days = try [
            testDate(year: 2019, month: 4, day: 30),
            testDate(year: 2026, month: 3, day: 1),
            testDate(year: 2026, month: 9, day: 20)
        ]
        let legacyDays = days.map { Self.legacyDayString(for: $0, calendar: calendar) }
        let legacy = try Self.decodeLegacy(firstSessionDay: legacyDays[0], distinctDaysUsed: legacyDays)
        let today = try testDate(year: 2026, month: 9, day: 23)

        let converted = RetentionCounters.recordingSessionStart(in: legacy, at: today, calendar: calendar)

        #expect(converted.firstSessionDay == "2019-04-30")
        #expect(converted.distinctDaysUsed == ["2019-04-30", "2026-03-01", "2026-09-20", "2026-09-23"])
    }

    /// 0.3.1 wrote Gregorian days with no marker, so a record it saved after
    /// a downgrade, or a record 0.3.2 saved and 0.3.1 re-saved, looks exactly
    /// like one written in the device's calendar. Re-reading its Gregorian
    /// year as Buddhist moves it back 543 years.
    @Test("A Gregorian record saved without a marker is not converted again", arguments: convertingCalendars)
    func gregorianRecordWithoutMarkerIsNotConvertedAgain(identifier: Calendar.Identifier) throws {
        let calendar = Self.calendar(identifier)
        let stored = try Self.decodeLegacy(firstSessionDay: "2026-09-01", distinctDaysUsed: ["2026-09-01", "2026-09-20"])
        let today = try testDate(year: 2026, month: 9, day: 23)

        let loaded = RetentionCounters.convertingDaysToGregorian(in: stored, at: today, calendar: calendar)
        let started = RetentionCounters.recordingSessionStart(in: loaded, at: today, calendar: calendar)

        #expect(loaded.firstSessionDay == "2026-09-01")
        #expect(loaded.distinctDaysUsed == ["2026-09-01", "2026-09-20"])
        #expect(started.distinctDaysUsed == ["2026-09-01", "2026-09-20", "2026-09-23"])
    }

    /// What a downgrade to 0.3.1 leaves behind: the days 0.3.2 wrote, then the
    /// days 0.3.1 appended in the device's own numbering. Each string is
    /// judged on its own, so neither half is read in the other's calendar.
    @Test("A record holding both numberings converts only the days that need it")
    func mixedRecordConvertsOnlyItsLegacyDays() throws {
        let calendar = Self.calendar(.buddhist)
        let stored = try Self.decodeLegacy(firstSessionDay: "2026-09-01", distinctDaysUsed: ["2026-09-01", "2569-09-20"])
        let today = try testDate(year: 2026, month: 9, day: 23)

        let loaded = RetentionCounters.convertingDaysToGregorian(in: stored, at: today, calendar: calendar)

        #expect(loaded.firstSessionDay == "2026-09-01")
        #expect(loaded.distinctDaysUsed == ["2026-09-01", "2026-09-20"])
    }

    /// A host that stores its own shape and rebuilds the record through the
    /// public initializer hands back legacy strings nothing marks as
    /// unconverted. Keeping them keeps a 2569 acquisition day and appends
    /// today beside its own Buddhist spelling.
    @Test("A legacy record rebuilt through the public initializer is still converted")
    func legacyRecordRebuiltByTheHostIsConverted() throws {
        let calendar = Self.calendar(.buddhist)
        let rebuilt = RetentionRecord(
            firstSessionDay: "2569-09-01",
            totalSessionsCount: 3,
            distinctDaysUsed: ["2569-09-01", "2569-09-23"]
        )
        let today = try testDate(year: 2026, month: 9, day: 23)

        let loaded = RetentionCounters.convertingDaysToGregorian(in: rebuilt, at: today, calendar: calendar)
        let started = RetentionCounters.recordingSessionStart(in: loaded, at: today, calendar: calendar)

        #expect(started.firstSessionDay == "2026-09-01")
        #expect(started.distinctDaysUsed == ["2026-09-01", "2026-09-23"])
    }

    /// A string that names no day in the window under any reading is not a
    /// day this package can place, so it is neither rewritten nor counted as
    /// recent. A far-future or non-date string sorts after every cutoff.
    @Test(
        "A day string outside the window in every reading stays verbatim and is not recent",
        arguments: [Calendar.Identifier.gregorian, .buddhist]
    )
    func dayOutsideEveryReadingStaysVerbatim(identifier: Calendar.Identifier) throws {
        let calendar = Self.calendar(identifier)
        let stored = try Self.decodeLegacy(
            firstSessionDay: "9999-12-31",
            distinctDaysUsed: ["9999-12-31", "not-a-day", "2026-09-20"]
        )
        let today = try testDate(year: 2026, month: 9, day: 23)

        let loaded = RetentionCounters.convertingDaysToGregorian(in: stored, at: today, calendar: calendar)
        let parameters = RetentionCounters.parameters(from: loaded, at: today, calendar: calendar)

        #expect(loaded.firstSessionDay == "9999-12-31")
        #expect(loaded.distinctDaysUsed == ["9999-12-31", "not-a-day", "2026-09-20"])
        #expect(parameters[PayloadKey.retentionDistinctDaysUsed] == "3")
        #expect(parameters[PayloadKey.retentionDistinctDaysUsedLastMonth] == "1")
    }

    /// A host compares what it loaded with what it would save, and a field
    /// the public initializer cannot set makes the two differ. The encoded
    /// keys are 0.3.1's, so a record round-trips through either release.
    @Test("A decoded record equals the same record built through the initializer, and encodes no extra key")
    func decodedRecordEqualsTheInitializedOne() throws {
        let opened = try testDate(year: 2026, month: 9, day: 23)
        let built = RetentionRecord(
            firstSessionDay: "2026-09-01",
            totalSessionsCount: 3,
            completedSessionsCount: 2,
            distinctDaysUsed: ["2026-09-01", "2026-09-23"],
            totalSessionSeconds: 40,
            previousSessionSeconds: 15,
            openSessionStartedAt: opened,
            lastActivityAt: opened
        )
        let json = try JSONSerialization.data(withJSONObject: [
            "firstSessionDay": "2026-09-01",
            "totalSessionsCount": 3,
            "completedSessionsCount": 2,
            "distinctDaysUsed": ["2026-09-01", "2026-09-23"],
            "totalSessionSeconds": 40,
            "previousSessionSeconds": 15,
            "openSessionStartedAt": opened.timeIntervalSinceReferenceDate,
            "lastActivityAt": opened.timeIntervalSinceReferenceDate
        ] as [String: Any])

        let decoded = try JSONDecoder().decode(RetentionRecord.self, from: json)
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(built)) as? [String: Any]
        )

        #expect(decoded == built)
        #expect(Set(encoded.keys) == [
            "firstSessionDay", "totalSessionsCount", "completedSessionsCount", "distinctDaysUsed",
            "totalSessionSeconds", "previousSessionSeconds", "openSessionStartedAt", "lastActivityAt"
        ])
    }

    /// The conversion is the recorder's, at load: the first signal reports
    /// from the loaded record before any session rewrites it, and the next
    /// save is what persists the converted days.
    @Test(
        "The recorder reports and saves Gregorian days from a record the host rebuilt in Buddhist numbering",
        .tempDirectory
    )
    func recorderConvertsTheRecordItLoads() async throws {
        let directory = try #require(TestTempDirectory.url)
        let today = try testDate(year: 2026, month: 9, day: 23)
        let seed = RetentionRecord(
            firstSessionDay: "2569-06-01",
            totalSessionsCount: 1,
            distinctDaysUsed: ["2569-06-01", "2569-09-20"]
        )
        let fixture = makeFixture(
            directory: directory,
            retention: SpyRetentionStore(seed: seed),
            calendar: Self.calendar(.buddhist),
            now: fixedClock(at: today)
        )

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        await fixture.recorder.drain()
        fixture.recorder.beginSession()

        let signal = try #require(fixture.transport.sentSignals.first)
        #expect(signal.parameters[PayloadKey.acquisitionFirstSessionDate] == "2026-06-01")
        #expect(signal.parameters[PayloadKey.retentionDistinctDaysUsedLastMonth] == "1")
        let saved = try #require(fixture.retention.saved.last)
        #expect(saved.firstSessionDay == "2026-06-01")
        #expect(saved.distinctDaysUsed == ["2026-06-01", "2026-09-20", "2026-09-23"])
    }

    // MARK: Private

    private static func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = .gmt
        return calendar
    }

    /// What the formatter wrote before day strings were Gregorian: the
    /// calendar's own year, month and day, with no era.
    private static func legacyDayString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Decoded rather than constructed, because a record from an earlier
    /// release reaches the counters through the host's storage and carries
    /// only the keys that release wrote.
    private static func decodeLegacy(firstSessionDay: String, distinctDaysUsed: [String]) throws -> RetentionRecord {
        let json: [String: Any] = [
            "firstSessionDay": firstSessionDay,
            "totalSessionsCount": 3,
            "distinctDaysUsed": distinctDaysUsed
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(RetentionRecord.self, from: data)
    }
}

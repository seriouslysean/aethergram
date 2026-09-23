import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// What a Retry-After value hands the core.
///
/// `Retry-After = HTTP-date / delay-seconds` (RFC 9110 §10.2.3), where an
/// HTTP-date is one of three case-sensitive, fixed-spacing forms (§5.6.7). A
/// value that parses becomes a delay; one that does not is no instruction, and
/// the batch stays on the core's own schedule. The core bounds any finite delay
/// at its interval ceiling, so the adapter's only duty past parsing is never
/// to trap and never to hand over a non-finite or negative wait.
@Suite("TelemetryDeck Retry-After", .tags(.wireFormat))
struct TelemetryDeckRetryAfterTests {
    // MARK: Internal

    /// `delay-seconds = 1*DIGIT` and the three `HTTP-date` forms of RFC 9110
    /// §5.6.7, which a recipient must accept, including the two obsolete ones.
    /// asctime pads a one-digit day with a second SP, or writes two digits.
    @Test(
        "Retry-After parses delay-seconds and every HTTP-date form",
        arguments: [
            ("0", 0.0),
            ("120", 120.0),
            ("Sun, 06 Nov 1994 08:51:37 GMT", 120.0),
            ("Sunday, 06-Nov-94 08:51:37 GMT", 120.0),
            ("Sun Nov  6 08:51:37 1994", 120.0),
            ("Sun Nov 06 08:51:37 1994", 120.0)
        ]
    )
    func retryAfterParses(value: String, expected: TimeInterval) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == expected)
    }

    /// OWS around a field value is not part of it (RFC 9110 §5.5), and only SP
    /// and HTAB are OWS.
    @Test(
        "Space or tab around a Retry-After value is not part of it",
        arguments: [
            " 120\t",
            "\t \tSun, 06 Nov 1994 08:51:37 GMT  ",
            " Sunday, 06-Nov-94 08:51:37 GMT\t",
            "\tSun Nov  6 08:51:37 1994 "
        ]
    )
    func surroundingWhitespaceIsTrimmed(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == 120)
    }

    /// A value followed by anything is not a value the grammar produces. "120,
    /// 60" is two Retry-After field lines combined with a comma, as RFC 9110
    /// §5.3 lets a recipient on the path do.
    @Test(
        "A Retry-After with trailing input is refused",
        arguments: [
            "120abc",
            "120 abc",
            "120, 60",
            "Sun, 06 Nov 1994 08:51:37 GMT extra",
            "Sun, 06 Nov 1994 08:51:37 GMTx",
            "Sun, 06 Nov 1994 08:51:37 GMT, 120",
            "Sunday, 06-Nov-94 08:51:37 GMT x",
            "Sun Nov  6 08:51:37 1994 x",
            "Sun Nov  6 08:51:37 19945"
        ]
    )
    func trailingInputIsRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == nil)
    }

    /// Every SP in the grammar is exactly one, bar asctime's pad before a
    /// one-digit day, and a sender must not add more (RFC 9110 §5.6.7). A
    /// value spaced otherwise came from something that is not following the
    /// grammar, and a guess at what it meant is not an instruction.
    @Test(
        "A Retry-After with whitespace the grammar does not have is refused",
        arguments: [
            "1 20",
            "Sun,  06 Nov 1994 08:51:37 GMT",
            "Sun, 06  Nov 1994 08:51:37 GMT",
            "Sun, 06 Nov 1994  08:51:37 GMT",
            "Sun, 06 Nov 1994 08:51:37  GMT",
            "Sun, 06 Nov 1994 08:51:37\tGMT",
            "Sunday,  06-Nov-94 08:51:37 GMT",
            "Sun  Nov  6 08:51:37 1994",
            "Sun Nov 6 08:51:37 1994",
            "Sun Nov  06 08:51:37 1994",
            "Sun Nov  6 08:51:37  1994"
        ]
    )
    func extraInternalWhitespaceIsRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == nil)
    }

    /// "HTTP-date is case sensitive" (RFC 9110 §5.6.7); only cache recipients
    /// are relaxed from that, by RFC 9111 §4.2.
    @Test(
        "A Retry-After date with a name in the wrong case is refused",
        arguments: [
            "sun, 06 Nov 1994 08:51:37 GMT",
            "Sun, 06 nov 1994 08:51:37 GMT",
            "SUN, 06 NOV 1994 08:51:37 GMT",
            "Sun, 06 Nov 1994 08:51:37 gmt",
            "sunday, 06-Nov-94 08:51:37 GMT",
            "Sunday, 06-nov-94 08:51:37 GMT",
            "sun Nov  6 08:51:37 1994",
            "Sun nov  6 08:51:37 1994"
        ]
    )
    func wrongCaseNamesAreRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == nil)
    }

    /// Each form takes its own day-name and a fixed-width day: IMF-fixdate and
    /// asctime the three-letter name, rfc850 the full one, and IMF-fixdate and
    /// rfc850 exactly two day digits.
    @Test(
        "A Retry-After date mixing the forms' fields is refused",
        arguments: [
            "Sunday, 06 Nov 1994 08:51:37 GMT",
            "Sun, 06-Nov-94 08:51:37 GMT",
            "Sunday Nov  6 08:51:37 1994",
            "Sun, 6 Nov 1994 08:51:37 GMT",
            "Sunday, 6-Nov-94 08:51:37 GMT",
            "Sun, 06 Nov 94 08:51:37 GMT",
            "Sunday, 06-Nov-1994 08:51:37 GMT",
            "Sun, 06 Nov 1994 8:51:37 GMT"
        ]
    )
    func mixedFormFieldsAreRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == nil)
    }

    /// A date that names no instant is not one to wait for.
    @Test(
        "A Retry-After date that names no instant is refused",
        arguments: [
            "Mon, 30 Feb 2026 12:00:00 GMT",
            "Thu, 31 Apr 2026 12:00:00 GMT",
            "Sun, 29 Feb 2026 12:00:00 GMT",
            "Mon, 29 Feb 2100 12:00:00 GMT",
            "Sun, 00 Nov 1994 08:51:37 GMT",
            "Sun, 32 Oct 1994 08:51:37 GMT",
            "Sun, 06 Nov 1994 24:00:00 GMT",
            "Sun, 06 Nov 1994 08:60:00 GMT",
            "Sunday, 30-Feb-26 12:00:00 GMT",
            "Sun Feb 30 12:00:00 2026",
            "Sun Nov  6 24:00:00 1994"
        ]
    )
    func impossibleDatesAreRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == nil)
    }

    /// Feb 29 exists in a year divisible by 4, except a century not divisible
    /// by 400; a parser with the rule half right refuses a real date.
    @Test(
        "A Retry-After Feb 29 in a leap year is a real date",
        arguments: [
            ("Thu, 29 Feb 2024 12:00:00 GMT", 1_709_208_000.0),
            ("Tue, 29 Feb 2000 12:00:00 GMT", 951_825_600.0)
        ]
    )
    func leapDayParses(value: String, expected: TimeInterval) {
        #expect(TelemetryDeckTransport.httpDate(value, now: Self.windowNow)?.timeIntervalSince1970 == expected)
    }

    /// `time-of-day` runs to 23:59:60 for a leap second (RFC 9110 §5.6.7).
    /// Foundation's clock has no leap seconds, so 23:59:60 is read as the
    /// instant after 23:59:59, which is when a server that sent it next
    /// counts a whole second. A 60 anywhere else is no instant UTC has.
    @Test("A Retry-After leap second is the instant after 23:59:59")
    func leapSecondIsTheNextInstant() {
        #expect(TelemetryDeckTransport.httpDate("Tue, 30 Jun 2026 23:59:60 GMT", now: Self.windowNow)?
            .timeIntervalSince1970 == 1_782_864_000)
        #expect(TelemetryDeckTransport.retryAfter("Tue, 30 Jun 2026 23:59:60 GMT", now: Self.windowNow) == 1_339_200)
    }

    @Test(
        "A Retry-After second of 60 outside 23:59 is refused",
        arguments: [
            "Sun, 06 Nov 1994 08:51:60 GMT",
            "Tue, 30 Jun 2026 23:58:60 GMT",
            "Tue, 30 Jun 2026 22:59:60 GMT",
            "Tue, 30 Jun 2026 23:59:61 GMT"
        ]
    )
    func secondSixtyOutsideALeapSecondIsRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.windowNow) == nil)
    }

    /// RFC 9110 §5.6.7: an rfc850 date that "appears to be more than 50 years
    /// in the future" is the most recent past year with the same two digits.
    /// So the window is (now - 50y, now + 50y]: exactly 50 years ahead stays
    /// ahead, and one second more falls back a century. `windowNow` is
    /// 2026-06-15 12:00:00 GMT.
    @Test(
        "An rfc850 two-digit year lands in the century RFC 9110's 50-year window gives",
        arguments: [
            ("Monday, 15-Jun-76 11:59:59 GMT", 3_359_447_999.0),
            ("Monday, 15-Jun-76 12:00:00 GMT", 3_359_448_000.0),
            ("Tuesday, 15-Jun-76 12:00:01 GMT", 203_688_001.0),
            ("Saturday, 15-Jun-75 12:00:00 GMT", 3_327_825_600.0),
            ("Wednesday, 15-Jun-77 12:00:00 GMT", 235_224_000.0),
            ("Monday, 15-Jun-26 12:00:00 GMT", 1_781_524_800.0),
            ("Thursday, 15-Jun-00 12:00:00 GMT", 961_070_400.0)
        ]
    )
    func twoDigitYearCenturyWindow(value: String, expected: TimeInterval) {
        #expect(TelemetryDeckTransport.httpDate(value, now: Self.windowNow)?.timeIntervalSince1970 == expected)
    }

    /// The same boundary, as the delay the core is handed: one second past it
    /// is a date 50 years gone, so no wait at all.
    @Test("An rfc850 date one second past the 50-year window asks for no wait")
    func twoDigitYearPastTheWindowIsNoWait() {
        #expect(TelemetryDeckTransport.retryAfter("Monday, 15-Jun-76 12:00:00 GMT", now: Self.windowNow) == 1_577_923_200)
        #expect(TelemetryDeckTransport.retryAfter("Tuesday, 15-Jun-76 12:00:01 GMT", now: Self.windowNow) == 0)
    }

    /// The window is a span of instants, so it cannot depend on the zone the
    /// process runs in. A start date taken on the local calendar drifts by the
    /// zone's offset change across the 50 years.
    @Test("The rfc850 century window does not move with the process time zone")
    func twoDigitYearWindowIgnoresLocalZone() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for identifier in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/New_York"] {
            NSTimeZone.default = TimeZone(identifier: identifier) ?? saved
            #expect(TelemetryDeckTransport.httpDate("Monday, 15-Jun-76 12:00:00 GMT", now: Self.windowNow)?
                .timeIntervalSince1970 == 3_359_448_000, "zone \(identifier)")
            #expect(TelemetryDeckTransport.httpDate("Tuesday, 15-Jun-76 12:00:01 GMT", now: Self.windowNow)?
                .timeIntervalSince1970 == 203_688_001, "zone \(identifier)")
        }
    }

    /// The day-name is not checked against the date: RFC 9110 gives a
    /// recipient no rule for a mismatch, and the date fields are the ones
    /// that say when.
    @Test("A Retry-After day-name that does not match its date is still read by its date")
    func mismatchedDayNameIsReadByDate() {
        #expect(TelemetryDeckTransport.retryAfter("Mon, 06 Nov 1994 08:51:37 GMT", now: Self.rfcNow) == 120)
    }

    /// A date already past is "now", not a negative wait for the core to
    /// misread.
    @Test(
        "A Retry-After date already past is a zero delay",
        arguments: [
            "Sun, 06 Nov 1994 08:00:00 GMT",
            "Thu, 01 Jan 1970 00:00:00 GMT",
            "Mon, 01 Jan 0001 00:00:00 GMT"
        ]
    )
    func pastRetryAfterDateIsZero(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == 0)
    }

    /// The latest date the grammar can write is handed over as its finite
    /// distance; bounding it is the core's.
    @Test("A Retry-After date at year 9999 is handed over as its finite delay")
    func farFutureDateIsItsFiniteDelay() {
        #expect(TelemetryDeckTransport.retryAfter("Fri, 31 Dec 9999 23:59:59 GMT", now: Self.rfcNow) == 252_618_189_022)
    }

    /// Past `UInt64.max` a fixed-width integer parse overflows; the value is
    /// still a finite `Double` and goes to the core as one.
    @Test("A delay-seconds past UInt64.max is handed over finite, without trapping")
    func delaySecondsPastUInt64IsFinite() throws {
        let delay = try #require(TelemetryDeckTransport.retryAfter("18446744073709551616", now: Self.rfcNow))
        #expect(delay == 18_446_744_073_709_551_616)
        #expect(delay.isFinite)
    }

    /// `DIGIT` is `%x30-39` (RFC 5234 Appendix B.1). A digit from another
    /// script is not one, in a count or in a date.
    @Test(
        "A Retry-After with a non-ASCII digit is refused",
        arguments: [
            "\u{0661}\u{0662}\u{0660}",
            "\u{FF11}\u{FF12}\u{FF10}",
            "1\u{FF12}0",
            "Sun, \u{FF10}6 Nov 1994 08:51:37 GMT",
            "Sun, 06 Nov 1994 08:5\u{0661}:37 GMT",
            "Sunday, 06-Nov-\u{0669}4 08:51:37 GMT",
            "Sun Nov  6 08:51:37 199\u{FF14}"
        ]
    )
    func nonASCIIDigitsAreRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == nil)
    }

    /// Anything outside the grammar is refused rather than guessed at: a
    /// sign, a fraction, a unit, a zone other than GMT, or a count too large
    /// for a `Double` to hold.
    @Test(
        "A Retry-After outside the grammar is refused",
        arguments: [
            "",
            "   ",
            "-5",
            "-0",
            "+5",
            "1.5",
            "5s",
            "0x10",
            "1e3",
            "Sun, 06 Nov 1994 08:51:37 PST",
            "Sun, 06 Nov 1994 08:51:37 UTC",
            "Sun, 06 Nov 1994 08:51:37 +0000",
            "Foo, 06 Nov 1994 08:51:37 GMT",
            "Sun, 06 Foo 1994 08:51:37 GMT",
            String(repeating: "9", count: 400)
        ]
    )
    func malformedRetryAfterIsRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.rfcNow) == nil)
    }

    // MARK: Private

    /// RFC 9110's own example instant, Sun, 06 Nov 1994 08:49:37 GMT, so each
    /// date form above is two minutes ahead of it.
    private static let rfcNow = Date(timeIntervalSince1970: 784_111_777)

    /// 2026-06-15 12:00:00 GMT: whole-hour, and in no year's Feb 29, so 50
    /// years either side is the same calendar day.
    private static let windowNow = Date(timeIntervalSince1970: 1_781_524_800)
}

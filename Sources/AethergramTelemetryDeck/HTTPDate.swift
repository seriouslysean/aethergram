import Foundation

/// RFC 9110 §5.6.7's `HTTP-date`, read to the letter of its grammar.
///
/// Written out rather than handed to `DateFormatter`, which reads names in any
/// case, digits from any script, and collapsed or missing spaces, and whose
/// two-digit start date is inclusive at the wrong end of the 50-year window
/// and taken on the process's calendar. What this admits:
///
/// - The three forms, each whole: IMF-fixdate, rfc850-date, asctime-date.
/// - Names and `GMT` case-sensitively, and only the day-name spelling the form
///   uses. The day-name is not checked against the date.
/// - Exactly the grammar's SPs, including asctime's second SP before a
///   one-digit day, and ASCII digits at the grammar's fixed widths.
/// - Only a date the Gregorian calendar has, with 23:59:60 as the instant after
///   23:59:59. Foundation's clock has no leap seconds, and a 60 anywhere else
///   is no instant UTC has.
/// - An rfc850 year as the latest one with those two digits that is not more
///   than 50 years after `now`, compared field by field in UTC.
enum HTTPDate {
    // MARK: Internal

    static func parse(_ value: String, now: Date) -> Date? {
        let bytes = Array(value.utf8)
        return imfFixdate(bytes) ?? rfc850Date(bytes, now: now) ?? asctimeDate(bytes)
    }

    // MARK: Private

    /// Year, month, day, hour, minute, second; ordered so a tuple comparison
    /// is a comparison of instants.
    private typealias Fields = (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)

    private static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let longDayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `day-name "," SP day SP month SP year SP time-of-day SP "GMT"`
    private static func imfFixdate(_ bytes: [UInt8]) -> Date? {
        var scanner = HTTPDateScanner(bytes)
        guard
            scanner.oneOf(dayNames) != nil, scanner.literal(", "),
            let day = scanner.digits(2), scanner.literal(" "),
            let month = scanner.oneOf(monthNames), scanner.literal(" "),
            let year = scanner.digits(4), scanner.literal(" "),
            let time = scanner.timeOfDay(), scanner.literal(" GMT"), scanner.isAtEnd
        else { return nil }
        return date((year, month + 1, day, time.hour, time.minute, time.second))
    }

    /// `day-name-l "," SP day "-" month "-" 2DIGIT SP time-of-day SP "GMT"`
    private static func rfc850Date(_ bytes: [UInt8], now: Date) -> Date? {
        var scanner = HTTPDateScanner(bytes)
        guard
            scanner.oneOf(longDayNames) != nil, scanner.literal(", "),
            let day = scanner.digits(2), scanner.literal("-"),
            let month = scanner.oneOf(monthNames), scanner.literal("-"),
            let twoDigitYear = scanner.digits(2), scanner.literal(" "),
            let time = scanner.timeOfDay(), scanner.literal(" GMT"), scanner.isAtEnd
        else { return nil }
        let current = fields(of: now)
        let limit = (current.year + 50, current.month, current.day, current.hour, current.minute, current.second)
        // The latest year with these digits no later than the limit: start a
        // century past `now`'s and step back at most twice.
        var year = current.year - current.year % 100 + 100 + twoDigitYear
        while (year, month + 1, day, time.hour, time.minute, time.second) > limit {
            year -= 100
        }
        return date((year, month + 1, day, time.hour, time.minute, time.second))
    }

    /// `day-name SP month SP ( 2DIGIT / ( SP 1DIGIT ) ) SP time-of-day SP year`
    private static func asctimeDate(_ bytes: [UInt8]) -> Date? {
        var scanner = HTTPDateScanner(bytes)
        guard
            scanner.oneOf(dayNames) != nil, scanner.literal(" "),
            let month = scanner.oneOf(monthNames), scanner.literal(" ")
        else { return nil }
        let day = scanner.literal(" ") ? scanner.digits(1) : scanner.digits(2)
        guard
            let day, scanner.literal(" "),
            let time = scanner.timeOfDay(), scanner.literal(" "),
            let year = scanner.digits(4), scanner.isAtEnd
        else { return nil }
        return date((year, month + 1, day, time.hour, time.minute, time.second))
    }

    /// The instant the fields name in UTC, or nil for one the calendar lacks.
    private static func date(_ fields: Fields) -> Date? {
        guard
            (1 ... 12).contains(fields.month),
            (1 ... daysIn(month: fields.month, year: fields.year)).contains(fields.day),
            (0 ... 23).contains(fields.hour),
            (0 ... 59).contains(fields.minute),
            (0 ... 59).contains(fields.second) || (fields.hour, fields.minute, fields.second) == (23, 59, 60)
        else { return nil }
        let days = daysSinceEpoch(year: fields.year, month: fields.month, day: fields.day)
        let seconds = days * 86400 + fields.hour * 3600 + fields.minute * 60 + fields.second
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Proleptic Gregorian days from 1970-01-01, counted in 400-year eras so
    /// the arithmetic needs no calendar or time zone.
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The inverse of `daysSinceEpoch`, for `now`'s own fields.
    private static func fields(of date: Date) -> Fields {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400
        let secondOfDay = seconds - days * 86400
        let shiftedDays = days + 719_468
        let era = (shiftedDays >= 0 ? shiftedDays : shiftedDays - 146_096) / 146_097
        let dayOfEra = shiftedDays - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day, secondOfDay / 3600, secondOfDay % 3600 / 60, secondOfDay % 60)
    }
}

/// A cursor over the value's bytes that consumes only on a match.
private struct HTTPDateScanner {
    // MARK: Lifecycle

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: Internal

    var isAtEnd: Bool {
        index == bytes.count
    }

    mutating func literal(_ text: String) -> Bool {
        let expected = Array(text.utf8)
        guard bytes[index...].starts(with: expected) else { return false }
        index += expected.count
        return true
    }

    /// The index of the name that matches, byte for byte.
    mutating func oneOf(_ names: [String]) -> Int? {
        names.firstIndex { literal($0) }
    }

    /// Exactly `count` ASCII digits; `DIGIT` is `%x30-39` (RFC 5234 B.1).
    mutating func digits(_ count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[index ..< index + count] {
            guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        index += count
        return value
    }

    /// `hour ":" minute ":" second`, each `2DIGIT`; ranges are the caller's.
    mutating func timeOfDay() -> (hour: Int, minute: Int, second: Int)? {
        guard
            let hour = digits(2), literal(":"),
            let minute = digits(2), literal(":"),
            let second = digits(2)
        else { return nil }
        return (hour, minute, second)
    }

    // MARK: Private

    private let bytes: [UInt8]
    private var index = 0
}

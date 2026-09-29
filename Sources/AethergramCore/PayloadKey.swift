import Foundation

/// Canonical names for every field the package attaches to a signal.
///
/// These are the package's vocabulary, not any vendor's. An adapter maps them
/// onto its wire names, which is what lets the same payload reach a second
/// backend without the core learning that backend exists — and what keeps a
/// dashboard built against the old vendor's field names working after the
/// transport swap.
///
/// The list is deliberately short. Every field here answers a question a
/// chart asks, survives data minimisation, and is proportionate in volume.
/// What the vendor's SDK sends that is not here stays out until a reason to
/// send it is written down, and each has its own reason for now:
///
/// - The accessibility settings and screen geometry: left out by decision,
///   although the vendor's charts for them then stay empty for these signals.
///   The SDK sends no preferred text size from an app extension either.
/// - Layout direction: the SDK sends `N/A` for it from any app extension, so
///   its chart is empty there under the SDK too.
/// - The debug, simulator, and App Store flags: `runContextChannel` replaced
///   them in payload 2.0.0. The adapter still sends the vendor's TestFlight
///   flag beside it.
/// - Operating system and locale: each repeats what is sent on its own, the
///   first as `devicePlatform`, the second as `userPreferenceRegion` and
///   `runContextLanguage`.
/// - Orientation, architecture, time zone, target environment, extension
///   identifier, colour scheme, and the calendar's day of month, day of year,
///   week, month, and quarter: no built-in chart was found reading them.
public enum PayloadKey {
    // MARK: App

    public static let appVersion = "app.version"
    public static let appBuild = "app.build"
    /// The two above joined, because a version-distribution chart groups on the
    /// pair and computing it downstream loses builds that share a version.
    public static let appVersionAndBuild = "app.versionAndBuild"

    // MARK: SDK

    /// Which transport wrote the signal. The vendor's SDK stamped the same
    /// family with its own values, so a chart can break the cutover down
    /// instead of reading it as a break in the data.
    public static let sdkName = "sdk.name"
    public static let sdkVersion = "sdk.version"
    /// The pair as one grouping key, matching how the vendor sent it.
    public static let sdkNameAndVersion = "sdk.nameAndVersion"

    // MARK: Device

    public static let deviceModelName = "device.modelName"
    public static let devicePlatform = "device.platform"
    /// `major.minor.patch`, as a bare number like the two below. The vendor's
    /// Swift SDK prefixes all three with the platform (`iOS 26.5.1`), while its
    /// Kotlin SDK sends the major and major.minor versions bare. The vendor
    /// documents each only as a String, so both forms conform, and a changed
    /// form would split every chart already grouped on this one.
    public static let deviceSystemVersion = "device.systemVersion"
    /// Major.minor only. Crash triage groups here; the patch component
    /// fragments the chart without changing a decision.
    public static let deviceSystemMajorMinorVersion = "device.systemMajorMinorVersion"
    /// Major only, which is what a decision to drop an OS version rests on,
    /// and one of the two granularities the vendor's prebuilt system-version
    /// chart switches between.
    public static let deviceSystemMajorVersion = "device.systemMajorVersion"

    // MARK: Run context

    public static let runContextChannel = "runContext.channel"
    /// The language the app runs in, which is always one it is localized in.
    public static let runContextLanguage = "runContext.language"

    // MARK: User preference

    /// The only geographic signal a native app has: no server-side derivation
    /// exists for app signals, so dropping this leaves no fallback behind it.
    public static let userPreferenceRegion = "userPreference.region"
    /// The language the user most prefers on the device, whether or not the
    /// app is localized in it. Where it differs from `runContextLanguage`, the
    /// app lacks a localization that user would have chosen.
    public static let userPreferenceLanguage = "userPreference.language"

    // MARK: Calendar

    /// Local hour, 0-23. Server receipt time cannot reconstruct it — receipt is
    /// UTC and the interesting question is local.
    public static let calendarHourOfDay = "calendar.hourOfDay"
    /// The local day, numbered as ISO 8601 numbers it: Monday 1 through
    /// Sunday 7, whatever the locale's first weekday.
    public static let calendarDayOfWeek = "calendar.dayOfWeek"
    /// `true` on a Saturday or a Sunday, derived from the day of week rather
    /// than from the locale's weekend.
    public static let calendarIsWeekend = "calendar.isWeekend"

    // MARK: Acquisition and retention

    public static let acquisitionFirstSessionDate = "acquisition.firstSessionDate"
    public static let retentionTotalSessionsCount = "retention.totalSessionsCount"
    public static let retentionDistinctDaysUsed = "retention.distinctDaysUsed"
    public static let retentionDistinctDaysUsedLastMonth = "retention.distinctDaysUsedLastMonth"
    public static let retentionAverageSessionSeconds = "retention.averageSessionSeconds"
    public static let retentionPreviousSessionSeconds = "retention.previousSessionSeconds"

    // MARK: Presets

    public static let purchaseType = "purchase.type"
    public static let purchaseCountryCode = "purchase.countryCode"
    public static let purchaseCurrencyCode = "purchase.currencyCode"
    public static let purchaseProductID = "purchase.productID"
    public static let errorID = "error.id"
}

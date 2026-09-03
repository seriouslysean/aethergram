import Foundation

/// Canonical names for every field the package attaches to a signal.
///
/// These are the package's vocabulary, not any vendor's. An adapter maps them
/// onto its wire names, which is what lets the same payload reach a second
/// backend without the core learning that backend exists — and what keeps a
/// dashboard built against the old vendor's field names working after the
/// transport swap.
///
/// The list is deliberately short. Every field here survived the audit in
/// `PLAN-AETHERGRAM-2026-08-30.md`: it names a decision it would change, it
/// survives data minimisation, and its volume is proportionate. Fields the SDK
/// sent that no chart reads — architecture, time zone, target environment,
/// extension identifier, colour scheme, layout direction, the six
/// accessibility flags, and screen geometry — are not here and are not coming
/// back without a reason written down.
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
    public static let deviceSystemVersion = "device.systemVersion"
    /// Major.minor only. Crash triage groups here; the patch component
    /// fragments the chart without changing a decision.
    public static let deviceSystemMajorMinorVersion = "device.systemMajorMinorVersion"

    // MARK: Run context

    public static let runContextIsDebug = "runContext.isDebug"
    public static let runContextIsSimulator = "runContext.isSimulator"
    public static let runContextIsTestFlight = "runContext.isTestFlight"
    public static let runContextIsAppStore = "runContext.isAppStore"

    // MARK: User preference

    /// The only geographic signal a native app has: no server-side derivation
    /// exists for app signals, so dropping this leaves no fallback behind it.
    public static let userPreferenceRegion = "userPreference.region"
    public static let userPreferenceLanguage = "userPreference.language"

    // MARK: Calendar

    /// Local hour, 0-23. Server receipt time cannot reconstruct it — receipt is
    /// UTC and the interesting question is local.
    public static let calendarHourOfDay = "calendar.hourOfDay"
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

import AethergramCore
import Foundation

/// The adapter's whole reason to exist: canonical package names on one side,
/// vendor wire names on the other.
///
/// Keeping the table here is what lets `AethergramCore` stay free of the
/// string `TelemetryDeck` while dashboards built against the vendor's field
/// names keep resolving after the SDK is gone. A chart reading
/// `TelemetryDeck.Retention.totalSessionsCount` does not learn that the
/// counter is now ours.
///
/// Anything absent from a table passes through unchanged, which is correct for
/// consumer-owned names: those are domain vocabulary and no adapter should be
/// renaming them.
enum TelemetryDeckWireNames {
    // MARK: Internal

    static func signalName(for name: String) -> String {
        presetSignalNames[name] ?? name
    }

    static func payload(from parameters: [String: String]) -> [String: String] {
        var mapped: [String: String] = [:]
        mapped.reserveCapacity(parameters.count)
        for (key, value) in parameters {
            mapped[parameterKeys[key] ?? key] = wireValue(forKey: key, value: value)
        }
        return mapped
    }

    // MARK: Private

    /// Both vendor-namespaced names bypass the SDK's signal prefix, which is
    /// why the core leaves preset names unprefixed.
    private static let presetSignalNames: [String: String] = [
        PresetSignal.purchaseCompleted.rawValue: "TelemetryDeck.Purchase.completed",
        PresetSignal.errorOccurred.rawValue: "TelemetryDeck.Error.occurred"
    ]

    private static let parameterKeys: [String: String] = [
        PayloadKey.appVersion: "TelemetryDeck.AppInfo.version",
        PayloadKey.appBuild: "TelemetryDeck.AppInfo.buildNumber",
        PayloadKey.appVersionAndBuild: "TelemetryDeck.AppInfo.versionAndBuildNumber",

        // The vendor's own SDK filled this family with "SwiftSDK"; ours fills
        // it with "Aethergram", so one dashboard breaks down by transport.
        // `SDK.buildType` is not part of the family and is not sent.
        PayloadKey.sdkName: "TelemetryDeck.SDK.name",
        PayloadKey.sdkVersion: "TelemetryDeck.SDK.version",
        PayloadKey.sdkNameAndVersion: "TelemetryDeck.SDK.nameAndVersion",

        PayloadKey.deviceModelName: "TelemetryDeck.Device.modelName",
        PayloadKey.devicePlatform: "TelemetryDeck.Device.platform",
        PayloadKey.deviceSystemVersion: "TelemetryDeck.Device.systemVersion",
        PayloadKey.deviceSystemMajorMinorVersion: "TelemetryDeck.Device.systemMajorMinorVersion",

        PayloadKey.runContextIsDebug: "TelemetryDeck.RunContext.isDebug",
        PayloadKey.runContextIsSimulator: "TelemetryDeck.RunContext.isSimulator",
        PayloadKey.runContextIsTestFlight: "TelemetryDeck.RunContext.isTestFlight",
        PayloadKey.runContextIsAppStore: "TelemetryDeck.RunContext.isAppStore",

        PayloadKey.userPreferenceRegion: "TelemetryDeck.UserPreference.region",
        PayloadKey.userPreferenceLanguage: "TelemetryDeck.UserPreference.language",

        // The vendor documents `hourOfDay` by name; `isWeekend` is the other
        // half of the only question a party game asks of a calendar.
        PayloadKey.calendarHourOfDay: "TelemetryDeck.Calendar.hourOfDay",
        PayloadKey.calendarIsWeekend: "TelemetryDeck.Calendar.isWeekend",

        PayloadKey.acquisitionFirstSessionDate: "TelemetryDeck.Acquisition.firstSessionDate",
        PayloadKey.retentionTotalSessionsCount: "TelemetryDeck.Retention.totalSessionsCount",
        PayloadKey.retentionDistinctDaysUsed: "TelemetryDeck.Retention.distinctDaysUsed",
        PayloadKey.retentionDistinctDaysUsedLastMonth: "TelemetryDeck.Retention.distinctDaysUsedLastMonth",
        PayloadKey.retentionAverageSessionSeconds: "TelemetryDeck.Retention.averageSessionSeconds",
        PayloadKey.retentionPreviousSessionSeconds: "TelemetryDeck.Retention.previousSessionSeconds",

        PayloadKey.purchaseType: "TelemetryDeck.Purchase.type",
        PayloadKey.purchaseCountryCode: "TelemetryDeck.Purchase.countryCode",
        PayloadKey.purchaseCurrencyCode: "TelemetryDeck.Purchase.currencyCode",
        PayloadKey.purchaseProductID: "TelemetryDeck.Purchase.productID",

        PayloadKey.errorID: "TelemetryDeck.Error.id"
    ]

    /// The one field whose value, not just its name, differs on the wire.
    ///
    /// The vendor's SDK sends `hourOfDay` as `component + 1`, so midnight
    /// arrives as 1 and 11pm as 24. That is the vendor's convention and every
    /// chart built on it reads that way; the package keeps the honest 0-23 hour
    /// and the adapter shifts it, which is exactly the seam's job. Sending the
    /// unshifted hour would move every historical bar by one column.
    private static func wireValue(forKey key: String, value: String) -> String {
        guard key == PayloadKey.calendarHourOfDay, let hour = Int(value) else { return value }
        return "\(hour + 1)"
    }
}

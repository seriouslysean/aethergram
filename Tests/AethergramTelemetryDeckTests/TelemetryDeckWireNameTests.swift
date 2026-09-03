import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// The name table, pinned key by key.
///
/// Each right-hand string below was read out of the pinned SDK checkout, not
/// out of the adapter: the parameter names from `DefaultSignalPayload` and
/// `Signal+Helpers.calendarParameters`, the purchase and error names from
/// `Presets/TelemetryDeck+Purchases.swift` and `Presets/TelemetryDeck+Errors.swift`.
/// A dashboard built on them keeps resolving only while these hold.
@Suite("TelemetryDeck wire names", .tags(.wireFormat))
struct TelemetryDeckWireNameTests {
    // MARK: Internal

    static let expectedParameterKeys: [String: String] = [
        PayloadKey.appVersion: "TelemetryDeck.AppInfo.version",
        PayloadKey.appBuild: "TelemetryDeck.AppInfo.buildNumber",
        PayloadKey.appVersionAndBuild: "TelemetryDeck.AppInfo.versionAndBuildNumber",

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

    /// Values are deliberately non-numeric so the only field the adapter
    /// rewrites, `hourOfDay`, passes through here too. The shift gets its own
    /// tests below.
    @Test("Every canonical payload key maps to its vendor wire name")
    func parameterKeyTable() {
        var parameters: [String: String] = [:]
        for key in Self.expectedParameterKeys.keys {
            parameters[key] = "value-of-\(key)"
        }

        let mapped = TelemetryDeckWireNames.payload(from: parameters)

        #expect(mapped.count == Self.expectedParameterKeys.count)
        for (canonical, wireName) in Self.expectedParameterKeys {
            #expect(mapped[wireName] == "value-of-\(canonical)", "\(canonical) must map to \(wireName)")
            #expect(mapped[canonical] == nil, "\(canonical) must not also ride under its canonical name")
        }
    }

    /// The table above can only fail on a mapping that changed, never on one
    /// that was never written. `PayloadKey`'s constants are `static let`s and
    /// carry no reflection, so the declaration list is read from source.
    @Test("Every declared PayloadKey constant has a mapping")
    func everyPayloadKeyIsMapped() throws {
        let declared = try Self.declaredPayloadKeys()

        #expect(declared.count == Self.expectedParameterKeys.count)
        for key in declared {
            #expect(
                Self.expectedParameterKeys[key] != nil,
                "PayloadKey \"\(key)\" has no TelemetryDeck wire name; add one to the adapter's table"
            )
        }
    }

    @Test("Preset signal names take the vendor's namespaced form", arguments: [
        (PresetSignal.purchaseCompleted, "TelemetryDeck.Purchase.completed"),
        (PresetSignal.errorOccurred, "TelemetryDeck.Error.occurred")
    ])
    func presetSignalNames(preset: PresetSignal, wireName: String) {
        #expect(TelemetryDeckWireNames.signalName(for: preset.rawValue) == wireName)
    }

    @Test("Every preset has a mapping")
    func everyPresetIsMapped() {
        for preset in PresetSignal.allCases {
            #expect(
                TelemetryDeckWireNames.signalName(for: preset.rawValue).hasPrefix("TelemetryDeck."),
                "preset \(preset.rawValue) reaches the wire unmapped"
            )
        }
    }

    @Test("A consumer signal name passes through unchanged", arguments: [
        "Example.Game.started",
        "Example.Turn.sent",
        "purchase.attempted"
    ])
    func consumerSignalNamesPassThrough(name: String) {
        #expect(TelemetryDeckWireNames.signalName(for: name) == name)
    }

    @Test("A consumer parameter key passes through unchanged")
    func consumerParameterKeysPassThrough() {
        let mapped = TelemetryDeckWireNames.payload(from: ["packID": "starter", "roundIndex": "3"])

        #expect(mapped == ["packID": "starter", "roundIndex": "3"])
    }

    /// The SDK sends `"\((components.hour ?? -1) + 1)"`, so midnight arrives as
    /// 1 and 11pm as 24. The package keeps the honest 0-23 hour and the adapter
    /// carries the vendor's off-by-one, without which every historical bar
    /// moves a column.
    @Test("The hour of day rides one higher than canonical", arguments: [
        ("0", "1"),
        ("1", "2"),
        ("12", "13"),
        ("22", "23"),
        ("23", "24")
    ])
    func hourOfDayShift(canonical: String, onTheWire: String) {
        let mapped = TelemetryDeckWireNames.payload(from: [PayloadKey.calendarHourOfDay: canonical])

        #expect(mapped["TelemetryDeck.Calendar.hourOfDay"] == onTheWire)
    }

    @Test("A non-numeric hour is left alone rather than guessed at")
    func nonNumericHourPassesThrough() {
        let mapped = TelemetryDeckWireNames.payload(from: [PayloadKey.calendarHourOfDay: "unknown"])

        #expect(mapped["TelemetryDeck.Calendar.hourOfDay"] == "unknown")
    }

    /// The shift is keyed on `hourOfDay` alone. A numeric value under any other
    /// key, including one that looks like an hour, must arrive untouched.
    @Test("No other field's value is transformed")
    func onlyTheHourIsShifted() {
        let parameters = [
            PayloadKey.calendarHourOfDay: "9",
            PayloadKey.calendarIsWeekend: "true",
            PayloadKey.retentionTotalSessionsCount: "9",
            PayloadKey.retentionDistinctDaysUsed: "0",
            PayloadKey.retentionAverageSessionSeconds: "23",
            PayloadKey.appBuild: "42",
            "customHour": "9"
        ]

        let mapped = TelemetryDeckWireNames.payload(from: parameters)

        #expect(mapped["TelemetryDeck.Calendar.hourOfDay"] == "10")
        #expect(mapped["TelemetryDeck.Calendar.isWeekend"] == "true")
        #expect(mapped["TelemetryDeck.Retention.totalSessionsCount"] == "9")
        #expect(mapped["TelemetryDeck.Retention.distinctDaysUsed"] == "0")
        #expect(mapped["TelemetryDeck.Retention.averageSessionSeconds"] == "23")
        #expect(mapped["TelemetryDeck.AppInfo.buildNumber"] == "42")
        #expect(mapped["customHour"] == "9")
    }

    @Test("The mapping survives the round trip into the encoded body")
    func mappingReachesTheEncodedBody() throws {
        let signal = TelemetryDeckFixture.signal(
            name: PresetSignal.purchaseCompleted.rawValue,
            parameters: [
                PayloadKey.purchaseProductID: "com.example.app.pack.one",
                PayloadKey.calendarHourOfDay: "23",
                "packID": "starter"
            ],
            floatValue: 1.99
        )

        let element = try TelemetryDeckFixture.element(for: signal)

        #expect(try TelemetryDeckFixture.string(element["type"], "type") == "TelemetryDeck.Purchase.completed")
        let payload = try #require(element["payload"] as? [String: String])
        #expect(payload["TelemetryDeck.Purchase.productID"] == "com.example.app.pack.one")
        #expect(payload["TelemetryDeck.Calendar.hourOfDay"] == "24")
        #expect(payload["packID"] == "starter")
        #expect(payload["purchase.productID"] == nil)
    }

    /// The three SDK-identity fields are the only ones whose values the
    /// package fixes rather than reads, so they are asserted as literals: a
    /// test that recomputed them from `Aethergram` would keep passing through a
    /// rename that silently re-buckets every chart grouped on this family.
    @Test("The transport stamps its own identity on the encoded signal")
    func sdkIdentityReachesTheEncodedBody() throws {
        let environment = EnvironmentSnapshot(
            appVersion: "1.2",
            appBuild: "34",
            modelName: "iPhone17,1",
            platform: "iOS",
            systemVersion: "26.1.2",
            systemMajorMinorVersion: "26.1",
            isDebug: false,
            isSimulator: false,
            isTestFlight: false,
            isAppStore: true,
            region: "US",
            language: "en"
        )
        let signal = TelemetryDeckFixture.signal(parameters: environment.parameters)

        let element = try TelemetryDeckFixture.element(for: signal)

        let payload = try #require(element["payload"] as? [String: String])
        #expect(payload["TelemetryDeck.SDK.name"] == "Aethergram")
        #expect(payload["TelemetryDeck.SDK.version"] == "1.0.0")
        #expect(payload["TelemetryDeck.SDK.nameAndVersion"] == "Aethergram 1.0.0")
        #expect(payload["sdk.name"] == nil)
        #expect(payload["sdk.version"] == nil)
        #expect(payload["sdk.nameAndVersion"] == nil)
        // The one field with a documented vendor value; ours must not report
        // the SDK's name after the swap.
        #expect(payload["TelemetryDeck.SDK.name"] != "SwiftSDK")
        // Not in the vendor's list, so it must not appear.
        #expect(payload["TelemetryDeck.SDK.buildType"] == nil)
    }

    // MARK: Private

    /// Reads the `static let` string literals straight out of `PayloadKey.swift`,
    /// relative to this file. The package is always tested from a checkout, so
    /// a missing file is a real failure, not an environment quirk.
    private static func declaredPayloadKeys() throws -> [String] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/AethergramCore/PayloadKey.swift")

        let text = try String(contentsOf: source, encoding: .utf8)
        let declaration = /static let \w+ = "([^"]+)"/
        return text.matches(of: declaration).map { String($0.output.1) }
    }
}

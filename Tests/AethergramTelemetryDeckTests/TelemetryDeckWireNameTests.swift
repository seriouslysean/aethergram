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

        PayloadKey.runContextChannel: "TelemetryDeck.RunContext.channel",

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

        // One over the table: the channel key also emits the vendor's legacy
        // isTestFlight flag, which has no canonical payload key of its own.
        #expect(mapped.count == Self.expectedParameterKeys.count + 1)
        #expect(mapped["TelemetryDeck.RunContext.isTestFlight"] != nil)
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
        "Example.Alpha.started",
        "Example.Beta.sent",
        "purchase.attempted"
    ])
    func consumerSignalNamesPassThrough(name: String) {
        #expect(TelemetryDeckWireNames.signalName(for: name) == name)
    }

    @Test("A consumer parameter key passes through unchanged")
    func consumerParameterKeysPassThrough() {
        let mapped = TelemetryDeckWireNames.payload(from: ["itemID": "first", "stepIndex": "3"])

        #expect(mapped == ["itemID": "first", "stepIndex": "3"])
    }

    /// A caller key spelled as a wire name lands on the same wire key as the
    /// package key mapped to it. Consumer parameters win the core's merge, so
    /// they win here too. Dictionary order changes with capacity, so the filler
    /// sizes put the two colliding keys in both iteration orders; a winner
    /// chosen by iteration order fails at least one of them.
    @Test("A caller key colliding with a mapped package key wins in every iteration order", arguments: [
        ("TelemetryDeck.AppInfo.version", PayloadKey.appVersion, "1.0"),
        ("TelemetryDeck.RunContext.isTestFlight", PayloadKey.runContextChannel, RunContextChannel.beta.rawValue)
    ])
    func callerKeyWinsAWireNameCollision(wireName: String, packageKey: String, packageValue: String) {
        for fillerCount in 0 ..< 64 {
            var parameters = [wireName: "from-caller", packageKey: packageValue]
            for index in 0 ..< fillerCount {
                parameters["filler.\(index)"] = "\(index)"
            }

            let mapped = TelemetryDeckWireNames.payload(from: parameters)

            #expect(mapped[wireName] == "from-caller", "lost with \(fillerCount) filler keys")
        }
    }

    @Test("A beta channel also emits the vendor's legacy isTestFlight flag")
    func betaChannelEmitsLegacyTestFlightFlag() {
        let mapped = TelemetryDeckWireNames.payload(
            from: [PayloadKey.runContextChannel: RunContextChannel.beta.rawValue]
        )

        #expect(mapped["TelemetryDeck.RunContext.channel"] == "beta")
        #expect(mapped["TelemetryDeck.RunContext.isTestFlight"] == "true")
    }

    /// Sent reading false rather than omitted: a chart grouping or filtering on
    /// `isTestFlight == false` would read an absent key as missing, not false,
    /// which is the compatibility the flag is retained for.
    @Test(
        "Dev and store channels send the legacy isTestFlight flag as false",
        arguments: [RunContextChannel.dev, .store]
    )
    func nonBetaChannelsEmitLegacyTestFlightFlagAsFalse(channel: RunContextChannel) {
        let mapped = TelemetryDeckWireNames.payload(
            from: [PayloadKey.runContextChannel: channel.rawValue]
        )

        #expect(mapped["TelemetryDeck.RunContext.isTestFlight"] == "false")
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

    /// Consumer parameters win the merge, so `hourOfDay` can carry any integer
    /// a caller wrote. `Int.max + 1` traps, and the signal is already durable
    /// by then, so every relaunch would re-send it and crash again.
    @Test("An hour outside 0-23 passes through rather than trapping the send", arguments: [
        "9223372036854775807",
        "-9223372036854775808",
        "24",
        "-1"
    ])
    func outOfRangeHourPassesThrough(value: String) {
        let mapped = TelemetryDeckWireNames.payload(from: [PayloadKey.calendarHourOfDay: value])

        #expect(mapped["TelemetryDeck.Calendar.hourOfDay"] == value)
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
                PayloadKey.purchaseProductID: "com.example.app.product.one",
                PayloadKey.calendarHourOfDay: "23",
                "itemID": "first"
            ],
            floatValue: 1.99
        )

        let element = try TelemetryDeckFixture.element(for: signal)

        #expect(try TelemetryDeckFixture.string(element["type"], "type") == "TelemetryDeck.Purchase.completed")
        let payload = try #require(element["payload"] as? [String: String])
        #expect(payload["TelemetryDeck.Purchase.productID"] == "com.example.app.product.one")
        #expect(payload["TelemetryDeck.Calendar.hourOfDay"] == "24")
        #expect(payload["itemID"] == "first")
        #expect(payload["purchase.productID"] == nil)
    }

    /// The three SDK-identity fields are the only ones whose values the
    /// package fixes rather than reads, so they are asserted as literals: a
    /// test that recomputed them from `Aethergram` would keep passing through a
    /// rename that silently re-buckets every chart grouped on this family.
    ///
    /// The input carries the same literals for the same reason. The recorder
    /// stamps the identity itself rather than reading it back out of the
    /// environment, so a signal built here from the snapshot alone would carry
    /// none of these fields and the name table would go unexercised.
    @Test("The transport stamps its own identity on the encoded signal")
    func sdkIdentityReachesTheEncodedBody() throws {
        let environment = EnvironmentSnapshot(
            appVersion: "1.2",
            appBuild: "34",
            modelName: "iPhone17,1",
            platform: "iOS",
            systemVersion: "26.1.2",
            systemMajorMinorVersion: "26.1",
            channel: .store,
            region: "US",
            language: "en"
        )
        let identity = [
            PayloadKey.sdkName: "Aethergram",
            PayloadKey.sdkVersion: "2.0.0",
            PayloadKey.sdkNameAndVersion: "Aethergram 2.0.0"
        ]
        let signal = TelemetryDeckFixture.signal(parameters: environment.parameters.merging(identity) { $1 })

        let element = try TelemetryDeckFixture.element(for: signal)

        let payload = try #require(element["payload"] as? [String: String])
        #expect(payload["TelemetryDeck.SDK.name"] == "Aethergram")
        #expect(payload["TelemetryDeck.SDK.version"] == "2.0.0")
        #expect(payload["TelemetryDeck.SDK.nameAndVersion"] == "Aethergram 2.0.0")
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

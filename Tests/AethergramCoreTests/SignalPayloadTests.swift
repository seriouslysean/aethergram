@testable import AethergramCore
import Foundation
import AethergramTestSupport
import Testing

/// What actually rides on a signal: the authored default payload, the
/// clock-derived fields, the retention counters, and the consumer's own
/// parameters on top of all three.
@Suite("Signal payload", .tempDirectory)
struct SignalPayloadTests {
    /// A named case rather than a tuple: four booleans-and-a-path in positional
    /// form is exactly the shape that gets silently transposed on edit.
    struct NonShippingBuild {
        static let all: [NonShippingBuild] = [
            NonShippingBuild(isDebug: true, isSimulator: true, isMacOS: false, receiptPath: "/x/receipt"),
            NonShippingBuild(isDebug: true, isSimulator: false, isMacOS: false, receiptPath: "/x/receipt"),
            NonShippingBuild(isDebug: false, isSimulator: true, isMacOS: false, receiptPath: "/x/receipt"),
            NonShippingBuild(isDebug: false, isSimulator: true, isMacOS: false, receiptPath: "/x/sandboxReceipt"),
            NonShippingBuild(isDebug: false, isSimulator: false, isMacOS: true, receiptPath: "/x/receipt")
        ]

        let isDebug: Bool
        let isSimulator: Bool
        let isMacOS: Bool
        let receiptPath: String
    }

    /// 2026-01-03 15:00 UTC is a Saturday, so the weekend flag has a value the
    /// assertion can name rather than merely echo.
    @Test("A signal carries the environment, the calendar fields, and the counters")
    func recordedSignalCarriesEveryDefaultLayer() async throws {
        let directory = try #require(TestTempDirectory.url)
        let saturday = try testDate(year: 2026, month: 1, day: 3, hour: 15)
        let seed = RetentionRecord(
            firstSessionDay: "2026-01-01",
            totalSessionsCount: 4,
            // Four opened, four finished: the average divides by the finished
            // ones, so a seed without this reads as the no-data sentinel.
            completedSessionsCount: 4,
            distinctDaysUsed: ["2026-01-01", "2026-01-03"],
            totalSessionSeconds: 80,
            previousSessionSeconds: 12
        )
        let fixture = makeFixture(
            directory: directory,
            retention: SpyRetentionStore(seed: seed),
            environment: ["env.key": "env-value", PayloadKey.appVersion: "1.2.3"],
            now: fixedClock(at: saturday)
        )

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        await fixture.recorder.drain()

        let signal = try #require(fixture.transport.sentSignals.first)
        #expect(signal.recordedAt == saturday)
        #expect(signal.parameters["env.key"] == "env-value")
        #expect(signal.parameters[PayloadKey.calendarHourOfDay] == "15")
        #expect(signal.parameters[PayloadKey.calendarIsWeekend] == "true")
        #expect(signal.parameters[PayloadKey.acquisitionFirstSessionDate] == "2026-01-01")
        #expect(signal.parameters[PayloadKey.retentionTotalSessionsCount] == "4")
        #expect(signal.parameters[PayloadKey.retentionDistinctDaysUsed] == "2")
        #expect(signal.parameters[PayloadKey.retentionDistinctDaysUsedLastMonth] == "2")
        #expect(signal.parameters[PayloadKey.retentionAverageSessionSeconds] == "20")
        #expect(signal.parameters[PayloadKey.retentionPreviousSessionSeconds] == "12")
        // The environment is read once per process, not once per signal.
        #expect(fixture.environmentCalls.count == 1)
    }

    /// The package's defaults are context; a caller that names the same key
    /// means the more specific thing, so the caller wins.
    @Test("A caller parameter beats the package default on the same key")
    func callerParametersWinOverPackageDefaults() async throws {
        let directory = try #require(TestTempDirectory.url)
        let saturday = try testDate(year: 2026, month: 1, day: 3, hour: 15)
        let seed = RetentionRecord(firstSessionDay: "2026-01-01", totalSessionsCount: 1)
        let fixture = makeFixture(
            directory: directory,
            retention: SpyRetentionStore(seed: seed),
            environment: [PayloadKey.appVersion: "package-default"],
            now: fixedClock(at: saturday)
        )

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record(
            "alpha",
            parameters: [
                PayloadKey.appVersion: "caller-wins",
                PayloadKey.calendarHourOfDay: "99",
                PayloadKey.retentionTotalSessionsCount: "999"
            ]
        )
        await fixture.recorder.drain()

        let signal = try #require(fixture.transport.sentSignals.first)
        #expect(signal.parameters[PayloadKey.appVersion] == "caller-wins")
        #expect(signal.parameters[PayloadKey.calendarHourOfDay] == "99")
        #expect(signal.parameters[PayloadKey.retentionTotalSessionsCount] == "999")
    }

    @Test("A weekday signal reports its local hour and clears the weekend flag")
    func weekdaySignalReportsLocalHour() async throws {
        let directory = try #require(TestTempDirectory.url)
        let monday = try testDate(year: 2026, month: 1, day: 5, hour: 9)
        let fixture = makeFixture(directory: directory, now: fixedClock(at: monday))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("alpha")
        await fixture.recorder.drain()

        let signal = try #require(fixture.transport.sentSignals.first)
        #expect(signal.parameters[PayloadKey.calendarHourOfDay] == "9")
        #expect(signal.parameters[PayloadKey.calendarIsWeekend] == "false")
    }

    /// The prefix lets one dashboard hold several surfaces. Presets bypass it:
    /// their names are the package's, and a prefixed preset would not join with
    /// anything an adapter maps.
    @Test("The prefix applies to consumer signals and never to presets")
    func signalPrefixSkipsPresetSignals() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(
            directory: directory,
            configuration: testConfiguration(signalPrefix: "sk."),
            now: steppingClock(from: start)
        )

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.record("thing.happened")
        fixture.recorder.recordPurchaseCompleted(
            PurchaseDetails(
                productID: "p1",
                countryCode: "US",
                currencyCode: "USD",
                isSubscription: true,
                price: 4.99
            )
        )
        fixture.recorder.recordError(id: "decode.failure")
        await fixture.recorder.drain()

        #expect(fixture.transport.sentSignalNames == [
            "sk.thing.happened",
            PresetSignal.purchaseCompleted.rawValue,
            PresetSignal.errorOccurred.rawValue
        ])
    }

    @Test("The error preset carries the consumer's id under the canonical key")
    func errorPresetCarriesTheIdentifier() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.recordError(id: "decode.failure", parameters: ["stage": "restore"])
        await fixture.recorder.drain()

        let signal = try #require(fixture.transport.sentSignals.first)
        #expect(signal.parameters[PayloadKey.errorID] == "decode.failure")
        #expect(signal.parameters["stage"] == "restore")
        #expect(signal.floatValue == nil)
    }

    @Test("PurchaseDetails emits its three required fields, plus currency when present")
    func purchaseDetailsParameterShape() {
        let subscription = PurchaseDetails(
            productID: "p1",
            countryCode: "US",
            currencyCode: "USD",
            isSubscription: true,
            price: 4.99
        )
        #expect(subscription.parameters == [
            PayloadKey.purchaseType: "subscription",
            PayloadKey.purchaseCountryCode: "US",
            PayloadKey.purchaseProductID: "p1",
            PayloadKey.purchaseCurrencyCode: "USD"
        ])

        let oneTime = PurchaseDetails(
            productID: "p2",
            countryCode: "JP",
            currencyCode: nil,
            isSubscription: false,
            price: nil
        )
        #expect(oneTime.parameters == [
            PayloadKey.purchaseType: "one-time-purchase",
            PayloadKey.purchaseCountryCode: "JP",
            PayloadKey.purchaseProductID: "p2"
        ])
    }

    /// 1200 JPY leaves as 1200, not as a dollar figure. The SDK this package
    /// replaces carried a hardcoded rate table that silently under-reports, and
    /// the native amount plus its currency code is what replaces it.
    @Test("A purchase price rides floatValue unconverted")
    func purchasePriceRidesFloatValueWithoutConversion() async throws {
        let directory = try #require(TestTempDirectory.url)
        let start = try testDate(year: 2026, month: 1, day: 5)
        let fixture = makeFixture(directory: directory, now: steppingClock(from: start))

        fixture.recorder.updateConsent(.granted)
        fixture.recorder.recordPurchaseCompleted(
            PurchaseDetails(
                productID: "p1",
                countryCode: "JP",
                currencyCode: "JPY",
                isSubscription: false,
                price: 1200
            )
        )
        await fixture.recorder.drain()

        let signal = try #require(fixture.transport.sentSignals.first)
        #expect(signal.floatValue == 1200)
        #expect(signal.parameters[PayloadKey.purchaseCurrencyCode] == "JPY")
        #expect(signal.parameters[PayloadKey.purchaseCountryCode] == "JP")
    }

    /// Asserts the key *set*, not a sample of it, so a field the audit dropped
    /// cannot quietly reappear without failing here.
    /// Regression, caught by the first sim walk of this transport rather than
    /// by any static check: a simulator ships a receipt file named `receipt`,
    /// so deriving `isAppStore` from the receipt name reported every simulator
    /// run as an App Store install. The four run-context flags exist to
    /// separate real usage from ours, so that answer put a developer's own
    /// device inside every App Store filter.
    ///
    /// The channel matrix matches the SDK this replaces
    /// (`Signal+Helpers.swift:109-131`): debug and simulator short-circuit both
    /// flags, and App Store is the negation of TestFlight rather than a second
    /// receipt read.
    @Test(
        "Debug, simulator and macOS builds claim neither distribution channel",
        arguments: NonShippingBuild.all
    )
    func developmentBuildsClaimNoChannel(build: NonShippingBuild) {
        let channel = EnvironmentSnapshot.buildChannel(
            isDebug: build.isDebug,
            isSimulator: build.isSimulator,
            isMacOS: build.isMacOS,
            receiptPath: build.receiptPath,
            receiptExists: true
        )
        #expect(channel.isTestFlight == false)
        #expect(channel.isAppStore == false)
    }

    @Test("A shipping build is TestFlight or App Store, never both, and an absent receipt claims neither")
    func shippingBuildsClaimExactlyOneChannel() {
        let testFlight = EnvironmentSnapshot.buildChannel(
            isDebug: false,
            isSimulator: false,
            isMacOS: false,
            receiptPath: "/var/mobile/Containers/Data/Application/ABC/StoreKit/sandboxReceipt",
            receiptExists: true
        )
        #expect(testFlight.isTestFlight)
        #expect(!testFlight.isAppStore)

        let appStore = EnvironmentSnapshot.buildChannel(
            isDebug: false,
            isSimulator: false,
            isMacOS: false,
            receiptPath: "/var/mobile/Containers/Data/Application/ABC/StoreKit/receipt",
            receiptExists: true
        )
        #expect(!appStore.isTestFlight)
        #expect(appStore.isAppStore)

        // A Release build Xcode installs straight to a device has no receipt
        // file on disk: `appStoreReceiptURL` still returns the expected path,
        // but nothing was ever written there. Claiming App Store by negation
        // would misfile a developer's own device as a real user; claiming
        // TestFlight would misfile it into a channel it never went through.
        let noReceiptFile = EnvironmentSnapshot.buildChannel(
            isDebug: false,
            isSimulator: false,
            isMacOS: false,
            receiptPath: "/var/mobile/Containers/Data/Application/ABC/StoreKit/receipt",
            receiptExists: false
        )
        #expect(!noReceiptFile.isTestFlight)
        #expect(!noReceiptFile.isAppStore)

        // A nil path (the rare case `appStoreReceiptURL` itself returns nil)
        // is the same "nothing to read" case as a path with no file behind it.
        let missing = EnvironmentSnapshot.buildChannel(
            isDebug: false,
            isSimulator: false,
            isMacOS: false,
            receiptPath: nil,
            receiptExists: false
        )
        #expect(!missing.isTestFlight)
        #expect(!missing.isAppStore)
    }

    @Test("The environment snapshot emits exactly its declared keys")
    func environmentSnapshotEmitsExactlyItsDeclaredKeys() {
        let snapshot = EnvironmentSnapshot(
            appVersion: "1.2",
            appBuild: "34",
            modelName: "iPhone17,1",
            platform: "iOS",
            systemVersion: "26.1.2",
            systemMajorMinorVersion: "26.1",
            isDebug: false,
            isSimulator: true,
            isTestFlight: false,
            isAppStore: true,
            region: "US",
            language: "en"
        )

        let expected: Set<String> = [
            PayloadKey.appVersion,
            PayloadKey.appBuild,
            PayloadKey.appVersionAndBuild,
            PayloadKey.sdkName,
            PayloadKey.sdkVersion,
            PayloadKey.sdkNameAndVersion,
            PayloadKey.deviceModelName,
            PayloadKey.devicePlatform,
            PayloadKey.deviceSystemVersion,
            PayloadKey.deviceSystemMajorMinorVersion,
            PayloadKey.runContextIsDebug,
            PayloadKey.runContextIsSimulator,
            PayloadKey.runContextIsTestFlight,
            PayloadKey.runContextIsAppStore,
            PayloadKey.userPreferenceRegion,
            PayloadKey.userPreferenceLanguage
        ]
        #expect(Set(snapshot.parameters.keys) == expected)
        #expect(snapshot.parameters.count == expected.count)
        #expect(snapshot.parameters[PayloadKey.appVersionAndBuild] == "1.2 (build 34)")
        // Constants, so they hold for a snapshot built with any other values.
        #expect(snapshot.parameters[PayloadKey.sdkName] == "Aethergram")
        #expect(snapshot.parameters[PayloadKey.sdkNameAndVersion]
            == "Aethergram \(snapshot.parameters[PayloadKey.sdkVersion] ?? "")")
        #expect(snapshot.parameters[PayloadKey.runContextIsSimulator] == "true")
        #expect(snapshot.parameters[PayloadKey.runContextIsDebug] == "false")
    }

    @Test("Calendar parameters are the only clock-derived fields")
    func calendarParametersCoverHourAndWeekendOnly() throws {
        let saturday = try testDate(year: 2026, month: 1, day: 3, hour: 15)
        let parameters = EnvironmentSnapshot.calendarParameters(at: saturday, calendar: testCalendar)

        #expect(parameters == [
            PayloadKey.calendarHourOfDay: "15",
            PayloadKey.calendarIsWeekend: "true"
        ])
    }
}

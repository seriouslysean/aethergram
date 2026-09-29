import AethergramCore
@testable import AethergramTelemetryDeck
import AethergramTestSupport
import Foundation
import Synchronization
import Testing

/// The default payload against TelemetryDeck's documented contract, as these
/// sources stated it when they were read on 2026-09-29:
///
/// - https://github.com/TelemetryDeck/SwiftSDK/blob/58f436299d3f6710bcedc18aff26480aaf1879fc/Sources/TelemetryDeck/Signals/Signal.swift,
///   lines 45-135
/// - https://github.com/TelemetryDeck/SwiftSDK/blob/58f436299d3f6710bcedc18aff26480aaf1879fc/Sources/TelemetryDeck/Signals/Signal%2BHelpers.swift,
///   lines 16-52, 133-151, and 291-363
/// - https://github.com/TelemetryDeck/SwiftSDK/blob/58f436299d3f6710bcedc18aff26480aaf1879fc/Sources/TelemetryDeck/Helpers/SessionManager.swift,
///   lines 170-184
/// - https://github.com/TelemetryDeck/docs/blob/2b9c2108e482e51b755a176f1af68edd81b67106/ingest/default-parameters.md,
///   published at https://telemetrydeck.com/docs/ingest/default-parameters/
///
/// Drift on this package's side fails a test here. Drift on the vendor's side
/// does not: that takes someone re-reading the files above, and the date says
/// how old this snapshot is.
///
/// A signal reaches the assertions the way one reaches the vendor: recorded
/// through a `SignalRecorder`, captured at its transport, and encoded into a
/// request body by the adapter. Every fixture value is one a known defect
/// would change: a locale whose weekend is Friday and Saturday, a preferred
/// language the locale does not speak, a time zone where 00:30 is still the
/// previous day in UTC, and a version whose three granularities all differ.
@Suite("TelemetryDeck default payload contract", .tags(.wireFormat))
struct TelemetryDeckDefaultPayloadContractTests {
    // MARK: Internal

    /// Every `TelemetryDeck.*` key the payload carries: the table this package
    /// adopted from the vendor's list, plus `RunContext.channel`, which is its
    /// own.
    static let adoptedKeys: Set<String> = [
        "TelemetryDeck.AppInfo.version",
        "TelemetryDeck.AppInfo.buildNumber",
        "TelemetryDeck.AppInfo.versionAndBuildNumber",
        "TelemetryDeck.Device.modelName",
        "TelemetryDeck.Device.platform",
        "TelemetryDeck.Device.systemVersion",
        "TelemetryDeck.Device.systemMajorMinorVersion",
        "TelemetryDeck.Device.systemMajorVersion",
        "TelemetryDeck.RunContext.channel",
        "TelemetryDeck.RunContext.isTestFlight",
        "TelemetryDeck.RunContext.language",
        "TelemetryDeck.UserPreference.language",
        "TelemetryDeck.UserPreference.region",
        "TelemetryDeck.Calendar.hourOfDay",
        "TelemetryDeck.Calendar.dayOfWeek",
        "TelemetryDeck.Calendar.isWeekend",
        "TelemetryDeck.Acquisition.firstSessionDate",
        "TelemetryDeck.Retention.totalSessionsCount",
        "TelemetryDeck.Retention.distinctDaysUsed",
        "TelemetryDeck.Retention.distinctDaysUsedLastMonth",
        "TelemetryDeck.Retention.averageSessionSeconds",
        "TelemetryDeck.Retention.previousSessionSeconds",
        "TelemetryDeck.SDK.name",
        "TelemetryDeck.SDK.version",
        "TelemetryDeck.SDK.nameAndVersion"
    ]

    /// The namespaced keys `default-parameters.md` lists at `2b9c2108`, copied
    /// from it rather than from the adapter.
    static let vendorDocumentedKeys: Set<String> = [
        "TelemetryDeck.AppInfo.buildNumber",
        "TelemetryDeck.AppInfo.version",
        "TelemetryDeck.AppInfo.versionAndBuildNumber",
        "TelemetryDeck.Device.architecture",
        "TelemetryDeck.Device.modelName",
        "TelemetryDeck.Device.operatingSystem",
        "TelemetryDeck.Device.orientation",
        "TelemetryDeck.Device.platform",
        "TelemetryDeck.Device.screenResolutionHeight",
        "TelemetryDeck.Device.screenResolutionWidth",
        "TelemetryDeck.Device.screenScaleFactor",
        "TelemetryDeck.Device.systemMajorMinorVersion",
        "TelemetryDeck.Device.systemMajorVersion",
        "TelemetryDeck.Device.systemVersion",
        "TelemetryDeck.Device.timeZone",
        "TelemetryDeck.Device.screenDensity",
        "TelemetryDeck.Device.brand",
        "TelemetryDeck.RunContext.isAppStore",
        "TelemetryDeck.RunContext.isDebug",
        "TelemetryDeck.RunContext.isSimulator",
        "TelemetryDeck.RunContext.isTestFlight",
        "TelemetryDeck.RunContext.language",
        "TelemetryDeck.RunContext.locale",
        "TelemetryDeck.RunContext.targetEnvironment",
        "TelemetryDeck.RunContext.extensionIdentifier",
        "TelemetryDeck.RunContext.isSideLoaded",
        "TelemetryDeck.RunContext.sourceMarketplace",
        "TelemetryDeck.UserPreference.colorScheme",
        "TelemetryDeck.UserPreference.language",
        "TelemetryDeck.UserPreference.layoutDirection",
        "TelemetryDeck.UserPreference.region",
        "TelemetryDeck.SDK.name",
        "TelemetryDeck.SDK.nameAndVersion",
        "TelemetryDeck.SDK.version",
        "TelemetryDeck.SDK.buildType",
        "TelemetryDeck.Accessibility.isReduceMotionEnabled",
        "TelemetryDeck.Accessibility.isBoldTextEnabled",
        "TelemetryDeck.Accessibility.isInvertColorsEnabled",
        "TelemetryDeck.Accessibility.isDarkerSystemColorsEnabled",
        "TelemetryDeck.Accessibility.isReduceTransparencyEnabled",
        "TelemetryDeck.Accessibility.shouldDifferentiateWithoutColor",
        "TelemetryDeck.Accessibility.preferredContentSizeCategory",
        "TelemetryDeck.Navigation.identifier",
        "TelemetryDeck.Navigation.schemaVersion",
        "TelemetryDeck.Navigation.sourcePath",
        "TelemetryDeck.Navigation.destinationPath",
        "TelemetryDeck.Calendar.dayOfMonth",
        "TelemetryDeck.Calendar.dayOfWeek",
        "TelemetryDeck.Calendar.dayOfYear",
        "TelemetryDeck.Calendar.weekOfYear",
        "TelemetryDeck.Calendar.isWeekend",
        "TelemetryDeck.Calendar.monthOfYear",
        "TelemetryDeck.Calendar.quarterOfYear",
        "TelemetryDeck.Calendar.hourOfDay",
        "TelemetryDeck.Acquisition.firstSessionDate",
        "TelemetryDeck.Retention.averageSessionSeconds",
        "TelemetryDeck.Retention.distinctDaysUsed",
        "TelemetryDeck.Retention.totalSessionsCount",
        "TelemetryDeck.Retention.previousSessionSeconds",
        "TelemetryDeck.Retention.distinctDaysUsedLastMonth",
        "TelemetryDeck.API.Ingest.version",
        "TelemetryDeck.API.namespace"
    ]

    /// Keys the vendor documents or its SDK sends that this payload leaves out
    /// on purpose, each with its reason. Sending one again means editing this
    /// list, which makes it a decision rather than drift.
    static let deliberatelyAbsentKeys: [String: String] = {
        var keys: [String: String] = [:]
        for name in [
            "isReduceMotionEnabled",
            "isBoldTextEnabled",
            "isInvertColorsEnabled",
            "isDarkerSystemColorsEnabled",
            "isReduceTransparencyEnabled",
            "shouldDifferentiateWithoutColor"
        ] {
            keys["TelemetryDeck.Accessibility.\(name)"] = "an accessibility setting, left out by decision"
        }
        keys["TelemetryDeck.Accessibility.preferredContentSizeCategory"] =
            "left out by decision, and never sent from an app extension by the SDK (Signal+Helpers.swift:68-72)"

        for name in ["screenResolutionWidth", "screenResolutionHeight", "screenScaleFactor"] {
            keys["TelemetryDeck.Device.\(name)"] = "screen geometry, left out by decision"
        }
        for name in ["orientation", "architecture", "timeZone"] {
            keys["TelemetryDeck.Device.\(name)"] = "no built-in chart was found reading it"
        }
        keys["TelemetryDeck.Device.operatingSystem"] = "repeats Device.platform"
        for name in ["isAppStore", "isDebug", "isSimulator"] {
            keys["TelemetryDeck.RunContext.\(name)"] = "collapsed into RunContext.channel in payload 2.0.0"
        }
        keys["TelemetryDeck.RunContext.locale"] = "repeats UserPreference.region and RunContext.language"
        for name in ["targetEnvironment", "extensionIdentifier"] {
            keys["TelemetryDeck.RunContext.\(name)"] = "no built-in chart was found reading it"
        }
        keys["TelemetryDeck.UserPreference.colorScheme"] = "no built-in chart was found reading it"
        keys["TelemetryDeck.UserPreference.layoutDirection"] =
            "the SDK sends N/A from any app extension (Signal+Helpers.swift:346-352)"
        for name in ["dayOfMonth", "dayOfYear", "weekOfYear", "monthOfYear", "quarterOfYear"] {
            keys["TelemetryDeck.Calendar.\(name)"] = "no built-in chart was found reading it"
        }
        keys["TelemetryDeck.SDK.buildType"] = "documented, but the Swift SDK does not send it (Signal.swift:94-96)"
        // Signal.swift:47-66 and 107-110: the unprefixed names the SDK marks
        // deprecated in favour of the namespaced ones.
        for name in [
            "platform",
            "systemVersion",
            "majorSystemVersion",
            "majorMinorSystemVersion",
            "appVersion",
            "buildNumber",
            "isSimulator",
            "isDebug",
            "isTestFlight",
            "isAppStore",
            "modelName",
            "architecture",
            "operatingSystem",
            "targetEnvironment",
            "locale",
            "region",
            "appLanguage",
            "preferredLanguage",
            "telemetryClientVersion",
            "extensionIdentifier"
        ] {
            keys[name] = "deprecated in favour of its namespaced name"
        }
        return keys
    }()

    /// Every emitted key is in the adopted set and every adopted key is
    /// emitted, so no package key leaks through under its canonical name.
    @Test("The payload is exactly the adopted set")
    func payloadIsExactlyTheAdoptedSet() async throws {
        let payload = try await Self.recordedPayload(at: Self.mondayHalfPastMidnight())

        #expect(Set(payload.keys) == Self.adoptedKeys)
    }

    @Test("The payload invents no vendor key")
    func payloadInventsNoVendorKey() async throws {
        let payload = try await Self.recordedPayload(at: Self.mondayHalfPastMidnight())

        for key in payload.keys where key.hasPrefix("TelemetryDeck.") && key != "TelemetryDeck.RunContext.channel" {
            #expect(Self.vendorDocumentedKeys.contains(key), "\(key) is not in default-parameters.md")
        }
    }

    /// Monday 2026-01-05 at 00:30 in Jerusalem, which is 22:30 on Sunday in UTC.
    @Test("Values take the vendor's form")
    func valuesTakeTheVendorsForm() async throws {
        let payload = try await Self.recordedPayload(at: Self.mondayHalfPastMidnight())

        let expected: [String: String] = [
            // default-parameters.md:42-44 types all three only as String. Bare,
            // as the Kotlin SDK sends the major and major.minor versions and
            // this package always has.
            "TelemetryDeck.Device.systemVersion": "26.5.1",
            "TelemetryDeck.Device.systemMajorMinorVersion": "26.5",
            "TelemetryDeck.Device.systemMajorVersion": "26",
            // Signal.swift:90 and Signal+Helpers.swift:306-312: the language the app runs in.
            "TelemetryDeck.RunContext.language": "en",
            // Signal.swift:99 and Signal+Helpers.swift:314-318: the first preferred language's subtag.
            "TelemetryDeck.UserPreference.language": "de",
            // Signal.swift:101 and Signal+Helpers.swift:297-303: the locale's region.
            "TelemetryDeck.UserPreference.region": "IL",
            // Signal+Helpers.swift:50 and default-parameters.md:167: the local hour plus one.
            "TelemetryDeck.Calendar.hourOfDay": "1",
            // Signal+Helpers.swift:30,38 and default-parameters.md:161: ISO, Monday 1.
            "TelemetryDeck.Calendar.dayOfWeek": "1",
            // Signal+Helpers.swift:33,43 and default-parameters.md:164: Saturday or Sunday.
            "TelemetryDeck.Calendar.isWeekend": "false",
            // Signal.swift:71: `<version> (build <build>)`.
            "TelemetryDeck.AppInfo.versionAndBuildNumber": "3.4.0 (build 18)",
            // Signal.swift:95: `<name> <version>`.
            "TelemetryDeck.SDK.nameAndVersion": "Aethergram 2.1.0",
            // SessionManager.swift:177 and default-parameters.md:168: the local day of the first session.
            "TelemetryDeck.Acquisition.firstSessionDate": "2026-01-05"
        ]
        for (key, value) in expected {
            #expect(payload[key] == value, "\(key)")
        }
    }

    @Test(
        "Weekday and weekend follow ISO, not the locale",
        arguments: [
            (2, "5", "false"),
            (3, "6", "true"),
            (4, "7", "true"),
            (5, "1", "false")
        ]
    )
    func weekdayAndWeekendFollowISO(dayOfJanuary: Int, dayOfWeek: String, isWeekend: String) async throws {
        // The fixture's own weekend is Friday and Saturday, or Friday and
        // Sunday are not where the two answers part.
        try #require(Self.calendar.isDateInWeekend(Self.date(day: 2, hour: 12)))
        try #require(!Self.calendar.isDateInWeekend(Self.date(day: 4, hour: 12)))

        let payload = try await Self.recordedPayload(at: Self.date(day: dayOfJanuary, hour: 12))

        #expect(payload["TelemetryDeck.Calendar.dayOfWeek"] == dayOfWeek)
        #expect(payload["TelemetryDeck.Calendar.isWeekend"] == isWeekend)
    }

    @Test("Hour of day spans 1 to 24", arguments: [(0, "1"), (23, "24")])
    func hourOfDaySpansOneToTwentyFour(hour: Int, onTheWire: String) async throws {
        let payload = try await Self.recordedPayload(at: Self.date(day: 5, hour: hour, minute: 10))

        #expect(payload["TelemetryDeck.Calendar.hourOfDay"] == onTheWire)
    }

    @Test("Deliberately absent keys stay absent")
    func deliberatelyAbsentKeysStayAbsent() async throws {
        let payload = try await Self.recordedPayload(at: Self.mondayHalfPastMidnight())

        for (key, reason) in Self.deliberatelyAbsentKeys {
            #expect(payload[key] == nil, "\(key) is left out: \(reason)")
        }
    }

    /// SessionManager.swift:181-184 sends the signal under this name, once, when
    /// the first session after install starts.
    @Test("The install preset takes the vendor's name")
    func installPresetTakesTheVendorsName() async throws {
        #expect(
            TelemetryDeckWireNames.signalName(for: "acquisition.newInstallDetected")
                == "TelemetryDeck.Acquisition.newInstallDetected"
        )

        let element = try await Self.recordedElement(at: Self.mondayHalfPastMidnight()) { recorder in
            recorder.recordNewInstallDetected()
        }

        #expect(try TelemetryDeckFixture.string(element["type"], "type") == "TelemetryDeck.Acquisition.newInstallDetected")
    }

    // MARK: Private

    /// A settable clock, so every call of one recording reads the instant the
    /// test put there.
    private final class FixtureClock: Sendable {
        init(_ start: Date) {
            instant = Mutex(start)
        }

        var now: Date {
            instant.withLock { $0 }
        }

        func advance(_ seconds: TimeInterval) {
            instant.withLock { $0.addTimeInterval(seconds) }
        }

        private let instant: Mutex<Date>
    }

    private final class CapturingTransport: SignalTransport {
        var batches: [SignalBatch] {
            received.withLock { $0 }
        }

        func send(_ batch: SignalBatch) async -> TransportOutcome {
            received.withLock { $0.append(batch) }
            return .delivered
        }

        private let received = Mutex<[SignalBatch]>([])
    }

    private final class MemoryQueueStorage: SignalQueueStorage {
        func load() -> [Signal] {
            stored.withLock { $0 }
        }

        func persist(_ signals: [Signal]) {
            stored.withLock { $0 = signals }
        }

        func purge() {
            stored.withLock { $0 = [] }
        }

        private let stored = Mutex<[Signal]>([])
    }

    private final class MemoryRetentionStore: RetentionStore {
        func load() -> RetentionRecord? {
            stored.withLock { $0 }
        }

        func save(_ record: RetentionRecord) {
            stored.withLock { $0 = record }
        }

        func clear() {
            stored.withLock { $0 = nil }
        }

        private let stored = Mutex<RetentionRecord?>(nil)
    }

    /// A device calendar in Jerusalem, whose locale keeps a Friday-Saturday
    /// weekend.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_IL")
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .gmt
        return calendar
    }()

    /// The locale-level fields come through `current()`, which is where the
    /// two language derivations live. The process-level ones, the version, the
    /// build, the model, and the OS, cannot be pointed at a device from a test
    /// host, so they are literals.
    private static let environment: EnvironmentSnapshot = {
        let locale = EnvironmentSnapshot.current(
            locale: Locale(identifier: "en_IL"),
            preferredLanguages: ["de-DE", "en-US"]
        )
        return EnvironmentSnapshot(
            appVersion: "3.4.0",
            appBuild: "18",
            modelName: "iPhone18,1",
            platform: "iOS",
            systemMajorVersion: 26,
            systemMinorVersion: 5,
            systemPatchVersion: 1,
            channel: .store,
            region: locale.region,
            preferredLanguage: locale.preferredLanguage,
            appLanguage: locale.appLanguage
        )
    }()

    private static func date(day: Int, hour: Int, minute: Int = 0) throws -> Date {
        let components = DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute)
        return try #require(calendar.date(from: components))
    }

    private static func mondayHalfPastMidnight() throws -> Date {
        try date(day: 5, hour: 0, minute: 30)
    }

    /// The payload of one consumer signal, recorded as a host records it.
    private static func recordedPayload(at date: Date) async throws -> [String: String] {
        let element = try await recordedElement(at: date) { $0.record("Example.Alpha.started") }
        return try #require(element["payload"] as? [String: String])
    }

    /// Records through a recorder, captures the batch at its transport, and
    /// returns the element the adapter encodes for the signal `record` made.
    ///
    /// One session opens and ends before it, so the counters carry a previous
    /// session's length, and a second opens; all of it inside the minute
    /// `date` names.
    private static func recordedElement(
        at date: Date,
        record: (SignalRecorder) -> Void
    ) async throws -> [String: Any] {
        let clock = FixtureClock(date)
        let transport = CapturingTransport()
        let recorder = SignalRecorder(
            configuration: AethergramConfiguration(logSubsystem: "com.example.app.tests", transmitInterval: 3600),
            transport: transport,
            queueStorage: MemoryQueueStorage(),
            retentionStore: MemoryRetentionStore(),
            clientUserProvider: { "client-user" },
            environmentProvider: { environment.parameters },
            calendar: calendar,
            now: { clock.now }
        )
        recorder.updateConsent(.granted)
        try #require(recorder.beginSession())
        clock.advance(20)
        recorder.endSession()
        clock.advance(10)
        recorder.beginSession()
        clock.advance(10)
        record(recorder)
        await recorder.flushAndWait()

        let batches = transport.batches
        try #require(batches.count == 1 && batches[0].signals.count == 1)
        return try #require(TelemetryDeckFixture.elements(for: batches[0]).first)
    }
}

import Foundation

/// Which distribution channel a run came down.
///
/// `dev` is anything that is neither a TestFlight nor an App Store install:
/// a debug build, a simulator run, or a Release build sideloaded straight to
/// a device. `EnvironmentSnapshot.buildChannel` stays the source of truth for
/// telling the three apart.
public enum RunContextChannel: String, Sendable {
    case dev
    case beta
    case store

    init(isTestFlight: Bool, isAppStore: Bool) {
        self = isTestFlight ? .beta : (isAppStore ? .store : .dev)
    }
}

/// The authored default payload: what the package attaches to every signal
/// beyond what the consumer passed.
///
/// Authored, not inherited. Each field maps to a chart someone reads; see
/// `PayloadKey` for what was dropped and why. Values are captured once per
/// process because none of them change inside one — the clock-derived fields
/// are computed per signal instead, in `SignalRecorder`.
public struct EnvironmentSnapshot: Equatable, Sendable {
    // MARK: Lifecycle

    public init(
        appVersion: String,
        appBuild: String,
        modelName: String,
        platform: String,
        systemVersion: String,
        systemMajorMinorVersion: String,
        channel: RunContextChannel,
        region: String,
        language: String
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.modelName = modelName
        self.platform = platform
        self.systemVersion = systemVersion
        self.systemMajorMinorVersion = systemMajorMinorVersion
        self.channel = channel
        self.region = region
        self.language = language
    }

    // MARK: Public

    public let appVersion: String
    public let appBuild: String
    public let modelName: String
    public let platform: String
    public let systemVersion: String
    public let systemMajorMinorVersion: String
    public let channel: RunContextChannel
    public let region: String
    public let language: String

    /// The snapshot as payload parameters under canonical keys.
    ///
    /// The package's own identity is not among them: it is stamped by the
    /// recorder, so that an override of this payload cannot drop it.
    public var parameters: [String: String] {
        [
            PayloadKey.appVersion: appVersion,
            PayloadKey.appBuild: appBuild,
            PayloadKey.appVersionAndBuild: "\(appVersion) (build \(appBuild))",
            PayloadKey.deviceModelName: modelName,
            PayloadKey.devicePlatform: platform,
            PayloadKey.deviceSystemVersion: systemVersion,
            PayloadKey.deviceSystemMajorMinorVersion: systemMajorMinorVersion,
            PayloadKey.runContextChannel: channel.rawValue,
            PayloadKey.userPreferenceRegion: region,
            PayloadKey.userPreferenceLanguage: language
        ]
    }

    /// Reads the running process. `bundle` and `locale` are parameters so the
    /// snapshot is constructible in a test without the test's own bundle
    /// leaking in as an expectation.
    public static func current(
        bundle: Bundle = .main,
        locale: Locale = .current,
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) -> EnvironmentSnapshot {
        let version = processInfo.operatingSystemVersion
        // One read, two answers: the presence of the identifier is what makes
        // this a simulator, and its value is the model to report.
        let simulatorModel = processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        let isSimulator = simulatorModel != nil
        let receipt = receiptPath(in: bundle)
        let distribution = buildChannel(
            isDebug: isDebugBuild,
            isSimulator: isSimulator,
            isMacOS: isMacOSPlatform,
            receiptPath: receipt,
            receiptExists: receipt.map(fileManager.fileExists(atPath:)) ?? false
        )
        return EnvironmentSnapshot(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            modelName: simulatorModel ?? hardwareModelName(),
            platform: platformName,
            systemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            systemMajorMinorVersion: "\(version.majorVersion).\(version.minorVersion)",
            channel: RunContextChannel(isTestFlight: distribution.isTestFlight, isAppStore: distribution.isAppStore),
            region: locale.region?.identifier ?? "",
            language: locale.language.languageCode?.identifier ?? ""
        )
    }

    /// Clock-derived fields, computed per signal rather than cached: an
    /// extension process can outlive an hour boundary, and hour-of-day is the
    /// field the whole `Calendar` family was reduced to.
    public static func calendarParameters(at date: Date, calendar: Calendar) -> [String: String] {
        let hour = calendar.component(.hour, from: date)
        return [
            PayloadKey.calendarHourOfDay: "\(hour)",
            PayloadKey.calendarIsWeekend: "\(calendar.isDateInWeekend(date))"
        ]
    }

    // MARK: Internal

    /// Which distribution channel this build came down. Pure, because
    /// `runContext.channel` exists to separate real usage from ours, and a
    /// wrong answer here quietly lets a developer's own simulator into an App
    /// Store filter.
    ///
    /// Debug and simulator short-circuit both answers, matching the SDK this
    /// replaces. App Store is a negation, not
    /// a receipt read: a simulator ships a receipt file named `receipt`, so
    /// reading the name directly reports every simulator run as App Store,
    /// which is what the first sim walk of this transport caught. A Release
    /// build Xcode installs straight to a device has no receipt file at all —
    /// `appStoreReceiptURL` still returns a path, but nothing exists there —
    /// so an absent file is neither channel rather than defaulting to App
    /// Store by the same negation. For an app extension `receiptPath` is its
    /// containing app's receipt, since the extension bundle never holds one;
    /// see `receiptURL(forBundleAt:receiptURL:)`.
    /// `AppTransaction.shared.environment` is the modern, async replacement
    /// for all of this, and it is async: this
    /// function is called from a synchronous snapshot, so adopting it would
    /// change the caller's shape and is deliberately not done here.
    static func buildChannel(
        isDebug: Bool,
        isSimulator: Bool,
        isMacOS: Bool,
        receiptPath: String?,
        receiptExists: Bool
    ) -> (isTestFlight: Bool, isAppStore: Bool) {
        guard !isDebug, !isSimulator, !isMacOS, receiptExists else { return (false, false) }
        let isTestFlight = receiptPath?.contains("sandboxReceipt") ?? false
        return (isTestFlight, !isTestFlight)
    }

    /// Where the receipt for the bundle at `bundleURL` lives, asking
    /// `receiptURL` for a bundle's own answer. Pure over URLs so the
    /// resolution is testable on a host that never reads a receipt.
    ///
    /// An extension's own bundle never holds a receipt, so an `.appex` two
    /// directories under an `.app` — `PlugIns/` or ExtensionKit's
    /// `Extensions/` — reads the containing app's. Any other layout, or a
    /// containing app with no answer, keeps the bundle's own.
    static func receiptURL(forBundleAt bundleURL: URL, receiptURL: (URL) -> URL?) -> URL? {
        guard bundleURL.pathExtension == "appex" else { return receiptURL(bundleURL) }
        let containingApp = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        guard containingApp.pathExtension == "app" else { return receiptURL(bundleURL) }
        return receiptURL(containingApp) ?? receiptURL(bundleURL)
    }

    // MARK: Private

    private static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    private static var platformName: String {
        #if os(iOS)
            "iOS"
        #elseif os(macOS)
            "macOS"
        #elseif os(watchOS)
            "watchOS"
        #elseif os(tvOS)
            "tvOS"
        #elseif os(visionOS)
            "visionOS"
        #else
            "unknown"
        #endif
    }

    /// macOS is a test host for this package rather than a shipping platform,
    /// so neither distribution channel claims it.
    private static var isMacOSPlatform: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    /// The receipt for `bundle`, or for its containing app when `bundle` is an
    /// app extension: an extension's own `appStoreReceiptURL` points inside
    /// the `.appex`, where no receipt is ever written, and would report every
    /// App Store install of the extension as `dev`.
    ///
    /// Not read on macOS: `appStoreReceiptURL` is deprecated there in favour of
    /// an async StoreKit call a synchronous snapshot cannot make, and
    /// `buildChannel` answers false for that platform anyway.
    private static func receiptPath(in bundle: Bundle) -> String? {
        #if os(macOS)
            nil
        #else
            receiptURL(forBundleAt: bundle.bundleURL) { url in
                url == bundle.bundleURL ? bundle.appStoreReceiptURL : Bundle(url: url)?.appStoreReceiptURL
            }?.path
        #endif
    }

    /// The machine's own hardware identifier. A simulator run reports what the
    /// simulator advertises instead, because `uname` here would describe the
    /// host Mac.
    private static func hardwareModelName() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }
}

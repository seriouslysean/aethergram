import AethergramCore
import Foundation

/// Everything vendor-specific about a TelemetryDeck destination.
///
/// It lives here rather than on `AethergramConfiguration` because none of it
/// means anything to a second backend: the core decides when to send, this
/// decides where.
public struct TelemetryDeckConfiguration: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - appID: The dashboard's app identifier. A public value that ships in
    ///     every binary by vendor convention, comparable to a tracking id.
    ///   - salt: Mixed into the client identifier before hashing. Defaults to
    ///     empty, which is the SDK's own default — changing it re-buckets every
    ///     existing user, so it stays empty for continuity, not by oversight.
    ///   - namespace: Vendor-documented segregation. Omitted by default,
    ///     which is the SDK's own behaviour.
    ///   - isTestMode: No default. A silent DEBUG-only default is exactly the
    ///     defect this replaced (Release simulator and TestFlight builds posted
    ///     to the live partition); every caller derives this explicitly, from
    ///     `testPartition(for:)`.
    public init(
        appID: String,
        salt: String = "",
        namespace: String? = nil,
        baseURL: URL = TelemetryDeckConfiguration.defaultBaseURL,
        isTestMode: Bool
    ) {
        self.appID = appID
        self.salt = salt
        self.namespace = namespace
        self.baseURL = baseURL
        self.isTestMode = isTestMode
    }

    // MARK: Public

    /// The vendor's documented ingest host.
    public static let defaultBaseURL: URL = {
        guard let url = URL(string: "https://nom.telemetrydeck.com") else {
            preconditionFailure("TelemetryDeck ingest host is a compile-time literal and must parse")
        }
        return url
    }()

    public let appID: String
    public let salt: String
    public let namespace: String?
    public let baseURL: URL
    public let isTestMode: Bool

    /// `v2/namespace/{ns}/` when a namespace is set, `v2/` otherwise — the
    /// vendor's documented ingest shape.
    ///
    /// `appending(path:)` handles the separator, so this cannot fail and the
    /// caller has no invalid-endpoint case to carry. The hand-rolled version
    /// re-parsed a concatenated string, which is what made the result optional
    /// in the first place.
    public var ingestURL: URL {
        if let namespace, !namespace.isEmpty {
            return baseURL.appending(path: "v2/namespace/\(namespace)/", directoryHint: .isDirectory)
        }
        return baseURL.appending(path: "v2/", directoryHint: .isDirectory)
    }

    /// Maps a vendor-neutral `EnvironmentSnapshot` to this vendor's Test Mode
    /// flag: only an App Store install may land in live figures, because that
    /// is the only channel `EnvironmentSnapshot` reports as real usage rather
    /// than a developer, CI, or beta run.
    ///
    /// The vendor's own SDK derived the same flag from `DEBUG` alone, which is
    /// what let a Release build on the simulator, a Release run on a developer
    /// device, and every TestFlight install post to the live partition and
    /// burn quota. `isAppStore` is the one flag `EnvironmentSnapshot` computes
    /// by negation after ruling out debug, simulator, and macOS, so a `false`
    /// answer already covers every one of those cases plus TestFlight.
    public static func testPartition(for snapshot: EnvironmentSnapshot) -> Bool {
        !snapshot.isAppStore
    }
}

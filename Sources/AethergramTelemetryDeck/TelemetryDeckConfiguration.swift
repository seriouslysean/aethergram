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
    /// The path is assembled explicitly rather than through `appending(path:)`
    /// because Foundation 6.2 and 6.3 disagree on that call's separator
    /// handling: a base URL already ending in a slash yields `v2//` on one and
    /// `v2/` on the other. Writing each separator exactly once here makes the
    /// URL identical on every Foundation. Every trailing slash is stripped
    /// rather than one, so a base ending in `//` cannot leave a doubled
    /// separator behind. Work happens on the *encoded* path so an encoded base
    /// segment survives verbatim, and the namespace is encoded as a single
    /// component, so a slash inside it stays data.
    ///
    /// A base URL carrying a query or fragment is outside this configuration's
    /// contract; both ride through onto the ingest URL untouched.
    public var ingestURL: URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            preconditionFailure("An absolute base URL must decompose into URLComponents")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        path += "/v2/"
        if let namespace, !namespace.isEmpty {
            path += "namespace/\(Self.encodedPathSegment(namespace))/"
        }
        components.percentEncodedPath = path
        guard let url = components.url else {
            preconditionFailure("Appending an encoded path to absolute components must recompose")
        }
        return url
    }

    /// Maps a vendor-neutral `EnvironmentSnapshot` to this vendor's Test Mode
    /// flag: only an App Store install may land in live figures, because that
    /// is the only channel `EnvironmentSnapshot` reports as real usage rather
    /// than a developer, CI, or beta run.
    ///
    /// The vendor's own SDK derived the same flag from `DEBUG` alone, which is
    /// what let a Release build on the simulator, a Release run on a developer
    /// device, and every TestFlight install post to the live partition and
    /// burn quota. `.store` is the one case `EnvironmentSnapshot.channel`
    /// reaches only after ruling out debug, simulator, macOS, and TestFlight,
    /// so anything else already covers every one of those cases.
    public static func testPartition(for snapshot: EnvironmentSnapshot) -> Bool {
        snapshot.channel != .store
    }

    // MARK: Private

    /// `.urlPathAllowed` permits `/`, which would let a namespace invent path
    /// structure; removing it keeps the namespace one component.
    private static func encodedPathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
            preconditionFailure("Percent-encoding a String against a CharacterSet must succeed")
        }
        return encoded
    }
}

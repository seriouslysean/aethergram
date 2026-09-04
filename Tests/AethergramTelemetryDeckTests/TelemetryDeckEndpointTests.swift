@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// The URL the batch is posted to, spelled out.
///
/// The SDK builds the same string in `SignalManager.getServiceUrl(baseURL:namespace:)`:
/// a trailing slash forced onto the base, then `v2/namespace/{ns}/` or `v2/`.
/// A drift here does not fail loudly at runtime — it 404s, which the adapter
/// treats as permanent and drops.
@Suite("TelemetryDeck endpoint", .tags(.wireFormat))
struct TelemetryDeckEndpointTests {
    // MARK: Internal

    /// One row of the base-shape matrix.
    struct BaseShape: Sendable {
        let base: String
        let namespace: String?
        let expected: String
    }

    @Test("No namespace posts to the bare v2 path")
    func endpointWithoutNamespace() throws {
        let configuration = TelemetryDeckFixture.configuration()
        let request = try TelemetryDeckFixture.transport(configuration: configuration)
            .makeRequest(for: TelemetryDeckFixture.batch())

        #expect(request.url?.absoluteString == "https://nom.telemetrydeck.com/v2/")
    }

    @Test("A namespace posts to the namespaced v2 path")
    func endpointWithNamespace() throws {
        let configuration = TelemetryDeckFixture.configuration(namespace: "example-app")
        let request = try TelemetryDeckFixture.transport(configuration: configuration)
            .makeRequest(for: TelemetryDeckFixture.batch())

        #expect(request.url?.absoluteString == "https://nom.telemetrydeck.com/v2/namespace/example-app/")
    }

    /// An empty namespace is the same intent as none, matching the SDK's own
    /// `if let namespace, !namespace.isEmpty` guard.
    @Test("An empty namespace falls back to the bare v2 path")
    func endpointWithEmptyNamespace() {
        let configuration = TelemetryDeckFixture.configuration(namespace: "")

        #expect(configuration.ingestURL.absoluteString == "https://nom.telemetrydeck.com/v2/")
    }

    @Test("A base URL resolves the same with or without a trailing slash", arguments: [
        "https://ingest.example.test",
        "https://ingest.example.test/"
    ])
    func endpointNormalizesTrailingSlash(base: String) throws {
        let configuration = try TelemetryDeckFixture.configuration(baseURL: TelemetryDeckFixture.url(base))

        #expect(configuration.ingestURL.absoluteString == "https://ingest.example.test/v2/")
    }

    @Test("A namespaced base URL resolves the same with or without a trailing slash", arguments: [
        "https://ingest.example.test",
        "https://ingest.example.test/"
    ])
    func namespacedEndpointNormalizesTrailingSlash(base: String) throws {
        let configuration = try TelemetryDeckFixture.configuration(
            namespace: "ns",
            baseURL: TelemetryDeckFixture.url(base)
        )

        #expect(configuration.ingestURL.absoluteString == "https://ingest.example.test/v2/namespace/ns/")
    }

    /// The whole base-shape matrix, spelled out: root and path-prefixed bases,
    /// each with and without a trailing slash, each bare and namespaced. This
    /// is the regression guard for the separator itself, which doubled into
    /// `v2//` under Foundation 6.2 and resolved to `v2/` under 6.3.
    @Test("Every base shape resolves to one exact ingest URL", arguments: Self.matrix)
    func endpointMatrix(shape: BaseShape) throws {
        let configuration = try TelemetryDeckFixture.configuration(
            namespace: shape.namespace,
            baseURL: TelemetryDeckFixture.url(shape.base)
        )

        #expect(configuration.ingestURL.absoluteString == shape.expected)
    }

    /// A doubled separator hides inside the path, never the `//` of the scheme,
    /// so this reads the encoded path rather than the absolute string.
    @Test("No base shape produces an empty path segment", arguments: Self.matrix)
    func endpointHasNoEmptyPathSegment(shape: BaseShape) throws {
        let configuration = try TelemetryDeckFixture.configuration(
            namespace: shape.namespace,
            baseURL: TelemetryDeckFixture.url(shape.base)
        )
        let components = try #require(
            URLComponents(url: configuration.ingestURL, resolvingAgainstBaseURL: true)
        )

        #expect(!components.percentEncodedPath.contains("//"))
    }

    /// An already-encoded base segment is data, not structure: decoding and
    /// re-encoding it would silently repoint the ingest URL at `/tenant/west/`.
    @Test("An encoded base path segment survives verbatim")
    func endpointPreservesEncodedBaseSegment() throws {
        let configuration = try TelemetryDeckFixture.configuration(
            baseURL: TelemetryDeckFixture.url("https://ingest.example.test/tenant%2Fwest/")
        )

        #expect(configuration.ingestURL.absoluteString == "https://ingest.example.test/tenant%2Fwest/v2/")
    }

    /// The namespace is one path component. A slash, space, or percent inside
    /// it encodes rather than inventing structure the server would route on.
    @Test("A namespace encodes as a single path component", arguments: [
        ("a b", "https://ingest.example.test/v2/namespace/a%20b/"),
        ("a/b", "https://ingest.example.test/v2/namespace/a%2Fb/"),
        ("a%b", "https://ingest.example.test/v2/namespace/a%25b/")
    ])
    func endpointEncodesNamespace(namespace: String, expected: String) throws {
        let configuration = try TelemetryDeckFixture.configuration(
            namespace: namespace,
            baseURL: TelemetryDeckFixture.url("https://ingest.example.test")
        )

        #expect(configuration.ingestURL.absoluteString == expected)
    }

    @Test("The default base URL is the vendor's documented ingest host")
    func defaultBaseURL() {
        #expect(TelemetryDeckConfiguration.defaultBaseURL.absoluteString == "https://nom.telemetrydeck.com")
    }

    @Test("The request is a JSON POST", arguments: [nil, "example-app"] as [String?])
    func requestMethodAndContentType(namespace: String?) throws {
        let configuration = TelemetryDeckFixture.configuration(namespace: namespace)
        let request = try TelemetryDeckFixture.transport(configuration: configuration)
            .makeRequest(for: TelemetryDeckFixture.batch())

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    // MARK: Private

    private static let matrix: [BaseShape] = [
        BaseShape(base: "https://ingest.example.test", namespace: nil, expected: "https://ingest.example.test/v2/"),
        BaseShape(base: "https://ingest.example.test/", namespace: nil, expected: "https://ingest.example.test/v2/"),
        BaseShape(
            base: "https://ingest.example.test",
            namespace: "ns",
            expected: "https://ingest.example.test/v2/namespace/ns/"
        ),
        BaseShape(
            base: "https://ingest.example.test/",
            namespace: "ns",
            expected: "https://ingest.example.test/v2/namespace/ns/"
        ),
        BaseShape(
            base: "https://ingest.example.test/api",
            namespace: nil,
            expected: "https://ingest.example.test/api/v2/"
        ),
        BaseShape(
            base: "https://ingest.example.test/api/",
            namespace: nil,
            expected: "https://ingest.example.test/api/v2/"
        ),
        BaseShape(
            base: "https://ingest.example.test/api",
            namespace: "ns",
            expected: "https://ingest.example.test/api/v2/namespace/ns/"
        ),
        BaseShape(
            base: "https://ingest.example.test/api/",
            namespace: "ns",
            expected: "https://ingest.example.test/api/v2/namespace/ns/"
        )
    ]
}

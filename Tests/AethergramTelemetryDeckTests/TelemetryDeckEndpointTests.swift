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

    @Test("The default base URL is the vendor's documented ingest host")
    func defaultBaseURL() {
        #expect(TelemetryDeckConfiguration.defaultBaseURL.absoluteString == "https://nom.telemetrydeck.com")
    }

    @Test("The request is a JSON POST")
    func requestMethodAndContentType() throws {
        let request = try TelemetryDeckFixture.transport().makeRequest(for: TelemetryDeckFixture.batch())

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
}

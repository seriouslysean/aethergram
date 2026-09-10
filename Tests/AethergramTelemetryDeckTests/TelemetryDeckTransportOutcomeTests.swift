import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// What a response costs the queue.
///
/// The code list mirrors the SDK's `URLResponse.disposition()`: `.drop` for
/// 400, 401, 403, 404, 413, 422, 501 and 505, `.retry` for everything else
/// including a missing response. Widening the permanent set silently drops
/// signals a retry would have delivered.
@Suite("TelemetryDeck transport outcome", .tags(.wireFormat))
struct TelemetryDeckTransportOutcomeTests {
    // MARK: Internal

    @Test("A 2xx delivers", arguments: [200, 201, 202, 204, 299])
    func successCodesDeliver(code: Int) throws {
        #expect(try TelemetryDeckTransport.outcome(for: Self.response(code)) == .delivered)
    }

    /// The SDK drops these by name: Bad Request (400), Unauthorized (401),
    /// Forbidden (403), Not Found (404), Payload Too Large (413),
    /// Unprocessable Entity (422), Not Implemented (501), HTTP Version Not
    /// Supported (505).
    @Test("A rejection the server will repeat is permanent", arguments: [400, 401, 403, 404, 413, 422, 501, 505])
    func permanentCodesDrop(code: Int) throws {
        #expect(try TelemetryDeckTransport.outcome(for: Self.response(code)) == .permanent(reason: "http-\(code)"))
    }

    @Test("Throttling and server faults stay queued", arguments: [408, 429, 500, 502, 503, 504])
    func retryableCodesRequeue(code: Int) throws {
        #expect(try TelemetryDeckTransport.outcome(for: Self.response(code)) == .retryable(reason: "http-\(code)"))
    }

    /// The SDK's `disposition()` guards `as? HTTPURLResponse` and returns
    /// `.retry`. A response with no status carries no evidence the batch was
    /// rejected, so dropping it would lose signals on a proxy quirk.
    @Test("A non-HTTP response is retryable")
    func nonHTTPResponseIsRetryable() throws {
        let response = try URLResponse(
            url: TelemetryDeckFixture.url("https://nom.telemetrydeck.com/v2/"),
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )

        #expect(TelemetryDeckTransport.outcome(for: response) == .retryable(reason: "non-http-response"))
    }

    /// The one end-to-end case. Everything above asserts on the pieces; this
    /// proves they are wired together, against a stubbed protocol rather than
    /// the vendor's host.
    @Test("A stubbed 200 delivers end to end")
    func sendDeliversAgainstAStubbedSession() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = TelemetryDeckFixture.transport(session: URLSession(configuration: configuration))

        let outcome = await transport.send(TelemetryDeckFixture.batch())

        #expect(outcome == .delivered)
    }

    /// An adapter that persists a request body to disk leaves a decline or a
    /// reset with nothing to erase it — SECURITY.md calls that a bug in this
    /// model regardless of build configuration, so the check does not gate on
    /// `DEBUG`. Any file left over from an earlier run is cleared first so a
    /// stale one cannot fail this for the wrong reason.
    @Test("send does not persist a request body to the caches directory")
    func sendDoesNotPersistARequestBody() async {
        let envelopeName = "aethergram-debug-envelopes.ndjson"
        let cachesDirectories = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        for directory in cachesDirectories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(envelopeName))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = TelemetryDeckFixture.transport(session: URLSession(configuration: configuration))
        _ = await transport.send(TelemetryDeckFixture.batch())

        for directory in cachesDirectories {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(envelopeName).path))
        }
    }

    // MARK: Private

    private static func response(_ code: Int) throws -> HTTPURLResponse {
        try #require(try HTTPURLResponse(
            url: TelemetryDeckFixture.url("https://nom.telemetrydeck.com/v2/"),
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
    }
}

/// Answers every request with an empty 200. Stateless on purpose: a stub that
/// records requests would need synchronisation to be `Sendable`, and nothing
/// here needs to inspect what was sent — the body suites do that directly.
private final class StubURLProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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

    /// RFC 9110 §10.2.3 names 429 and 503 as the statuses that carry
    /// Retry-After. A throttled ingest that says when to come back and is
    /// retried on the fixed schedule anyway is hit again before it asked to be.
    @Test("A 429 or 503 carrying Retry-After says when to retry", arguments: [429, 503])
    func throttleCarriesRetryAfter(code: Int) throws {
        let response = try Self.response(code, headers: ["Retry-After": "120"])
        #expect(TelemetryDeckTransport.outcome(for: response, now: Self.now) == .retryableAfter(
            reason: "http-\(code)",
            delay: 120
        ))
    }

    /// Any other status that happens to carry the header is not one the RFC
    /// gives it meaning on, and stays on the core's own schedule.
    @Test("Retry-After on a status the RFC does not pair it with is ignored", arguments: [408, 500, 502, 504])
    func retryAfterOnOtherStatusesIsIgnored(code: Int) throws {
        let response = try Self.response(code, headers: ["Retry-After": "120"])
        #expect(TelemetryDeckTransport.outcome(for: response, now: Self.now) == .retryable(reason: "http-\(code)"))
    }

    /// A header that does not parse is no instruction at all; the batch is
    /// still retryable on the core's schedule rather than dropped.
    @Test("A 429 whose Retry-After does not parse falls back to a plain retry")
    func unparseableRetryAfterFallsBack() throws {
        let response = try Self.response(429, headers: ["Retry-After": "soon"])
        #expect(TelemetryDeckTransport.outcome(for: response, now: Self.now) == .retryable(reason: "http-429"))
    }

    /// `delay-seconds = 1*DIGIT` and the three `HTTP-date` forms of RFC 9110
    /// §5.6.7, which a recipient must accept, including the two obsolete ones.
    @Test(
        "Retry-After parses delay-seconds and every HTTP-date form",
        arguments: [
            ("0", 0.0),
            ("120", 120.0),
            (" 120\t", 120.0),
            ("Sun, 06 Nov 1994 08:51:37 GMT", 120.0),
            ("Sunday, 06-Nov-94 08:51:37 GMT", 120.0),
            ("Sun Nov  6 08:51:37 1994", 120.0)
        ]
    )
    func retryAfterParses(value: String, expected: TimeInterval) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.now) == expected)
    }

    /// A date already past is "now", not a negative wait for the core to
    /// misread.
    @Test("A Retry-After date already past is a zero delay")
    func pastRetryAfterDateIsZero() {
        #expect(TelemetryDeckTransport.retryAfter("Sun, 06 Nov 1994 08:00:00 GMT", now: Self.now) == 0)
    }

    /// Anything outside the grammar is refused rather than guessed at: a
    /// sign, a fraction, a unit, a zone other than GMT, or a count too large
    /// for a `Double` to hold.
    @Test(
        "A Retry-After outside the grammar is refused",
        arguments: [
            "",
            "-5",
            "+5",
            "1.5",
            "5s",
            "0x10",
            "Sun, 06 Nov 1994 08:51:37 PST",
            String(repeating: "9", count: 400)
        ]
    )
    func malformedRetryAfterIsRefused(value: String) {
        #expect(TelemetryDeckTransport.retryAfter(value, now: Self.now) == nil)
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

    /// RFC 9110's own example instant, Sun, 06 Nov 1994 08:49:37 GMT, so each
    /// date form above is two minutes ahead of it.
    private static let now = Date(timeIntervalSince1970: 784_111_777)

    private static func response(_ code: Int, headers: [String: String]? = nil) throws -> HTTPURLResponse {
        try #require(try HTTPURLResponse(
            url: TelemetryDeckFixture.url("https://nom.telemetrydeck.com/v2/"),
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: headers
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

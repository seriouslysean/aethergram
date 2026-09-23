import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// Which `URLSession` the transport sends over, and over what scheme.
///
/// A background session refuses completion-handler and async data tasks with
/// an `NSGenericException`, which aborts the host with a message about
/// completion handlers that does not name the transport. The transport traps
/// at the same moment, the first send, with one that names it and the
/// session. Not at construction: 0.3.1 constructed over a background session
/// without trapping, and a host that builds a transport and never sends —
/// consent withheld — must keep running.
@Suite("TelemetryDeck transport session", .serialized, .tags(.lifecycle))
struct TelemetryDeckTransportSessionTests {
    @Test("A default session constructs without trapping")
    func defaultSessionConstructs() {
        let session = URLSession(configuration: .ephemeral)
        _ = TelemetryDeckFixture.transport(session: session)
        session.invalidateAndCancel()
    }

    /// `URLSession.shared` carries the host's cookie store, URL cache, and
    /// registered `URLProtocol`s, so a default built on it would send a host
    /// cookie to the ingest and cache the ingest's replies beside the host's.
    @Test("The default session shares no cookie store or URL cache with the host")
    func defaultSessionSharesNothingWithTheHost() {
        let transport = TelemetryDeckTransport(
            configuration: TelemetryDeckFixture.configuration(),
            logSubsystem: "com.example.app.tests"
        )
        #expect(transport.session !== URLSession.shared)
        #expect(transport.session.configuration.httpCookieStorage == nil)
        #expect(transport.session.configuration.urlCache == nil)
    }

    /// Built once: a session per transport would be a connection pool per
    /// transport, and a host may build more than one.
    @Test("Two default transports share one session")
    func defaultTransportsShareOneSession() {
        let first = TelemetryDeckTransport(configuration: TelemetryDeckFixture.configuration(), logSubsystem: "a")
        let second = TelemetryDeckTransport(configuration: TelemetryDeckFixture.configuration(), logSubsystem: "b")
        #expect(first.session === second.session)
    }

    /// An `http` base would post every signal, the hashed user included, in
    /// cleartext. 0.3.x accepted one.
    @Test("An http base URL traps at construction")
    func cleartextBaseURLTraps() async {
        await #expect(processExitsWith: .failure) {
            guard let url = URL(string: "http://ingest.example.test") else { return }
            _ = TelemetryDeckFixture.configuration(baseURL: url)
        }
    }

    /// The scheme is case-insensitive (RFC 3986 §3.1), so an uppercase one is
    /// the same https and must not trap.
    @Test(
        "An https base URL in any case constructs",
        arguments: ["https://ingest.example.test", "HTTPS://ingest.example.test"]
    )
    func secureBaseURLConstructs(base: String) throws {
        let configuration = try TelemetryDeckFixture.configuration(baseURL: TelemetryDeckFixture.url(base))
        #expect(configuration.baseURL.absoluteString == base)
    }

    @Test("A host that builds a transport over a background session and never sends keeps running")
    func backgroundSessionConstructsWithoutTrapping() async {
        await #expect(processExitsWith: .success) {
            let configuration = URLSessionConfiguration.background(withIdentifier: "aethergram.tests.\(UUID())")
            _ = TelemetryDeckFixture.transport(session: URLSession(configuration: configuration))
        }
    }

    @Test("A send over a background session traps with a message that names the session")
    func backgroundSessionTrapsAtTheFirstSend() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let configuration = URLSessionConfiguration.background(withIdentifier: "aethergram.tests.\(UUID())")
            let transport = TelemetryDeckFixture.transport(session: URLSession(configuration: configuration))
            _ = await transport.send(TelemetryDeckFixture.batch())
        }
        let standardError = try #require(result).standardErrorContent
        #expect(String(decoding: standardError, as: UTF8.self)
            .contains("TelemetryDeckTransport cannot send over a background URLSession"))
    }
}

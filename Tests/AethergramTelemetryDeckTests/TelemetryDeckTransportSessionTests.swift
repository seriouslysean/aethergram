import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// Which `URLSession` the transport accepts.
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

import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// Which `URLSession` the transport accepts.
///
/// A background session refuses completion-handler and async data tasks with
/// an `NSGenericException` at the first send, which aborts the host long after
/// the misconfiguration that caused it. Refusing it at construction puts the
/// crash on the line that is wrong.
@Suite("TelemetryDeck transport session", .serialized, .tags(.lifecycle))
struct TelemetryDeckTransportSessionTests {
    @Test("A default session constructs without trapping")
    func defaultSessionConstructs() {
        let session = URLSession(configuration: .ephemeral)
        _ = TelemetryDeckFixture.transport(session: session)
        session.invalidateAndCancel()
    }

    @Test("A background session traps at construction rather than at the first send")
    func backgroundSessionTrapsAtConstruction() async {
        await #expect(processExitsWith: .failure) {
            let configuration = URLSessionConfiguration.background(withIdentifier: "aethergram.tests.\(UUID())")
            _ = TelemetryDeckFixture.transport(session: URLSession(configuration: configuration))
        }
    }
}

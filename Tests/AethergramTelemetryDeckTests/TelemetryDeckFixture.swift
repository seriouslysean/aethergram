import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import Testing

/// Shared construction for the wire-contract suites.
///
/// Every fixture is fixed rather than derived: the point of these tests is that
/// a byte the vendor's ingest reads cannot move without a failure, so a value
/// computed the same way the adapter computes it would prove nothing.
enum TelemetryDeckFixture {
    /// 2023-11-14T22:13:20 UTC. Chosen for a whole-second value so the encoded
    /// string is exact under a formatter with no fractional-seconds field.
    static let instant = Date(timeIntervalSince1970: 1_700_000_000)

    /// What `instant` must look like on the wire. `Z` in `DateFormatter` is the
    /// RFC 822 form, so the offset is `+0000`, not a literal `Z`.
    static let instantOnTheWire = "2023-11-14T22:13:20+0000"

    static func configuration(
        appID: String = "test-app-id",
        salt: String = "",
        namespace: String? = nil,
        baseURL: URL = TelemetryDeckConfiguration.defaultBaseURL,
        isTestMode: Bool = false
    ) -> TelemetryDeckConfiguration {
        TelemetryDeckConfiguration(
            appID: appID,
            salt: salt,
            namespace: namespace,
            baseURL: baseURL,
            isTestMode: isTestMode
        )
    }

    static func transport(
        configuration: TelemetryDeckConfiguration = TelemetryDeckFixture.configuration(),
        session: URLSession = .shared
    ) -> TelemetryDeckTransport {
        TelemetryDeckTransport(
            configuration: configuration,
            logSubsystem: "com.example.app.tests",
            session: session
        )
    }

    static func signal(
        name: String = "Example.Game.started",
        parameters: [String: String] = [:],
        floatValue: Double? = nil,
        recordedAt: Date = TelemetryDeckFixture.instant
    ) -> Signal {
        Signal(name: name, parameters: parameters, floatValue: floatValue, recordedAt: recordedAt)
    }

    static func batch(
        signals: [Signal] = [TelemetryDeckFixture.signal()],
        clientUser: String = "abc",
        sessionID: String = "test-session"
    ) -> SignalBatch {
        SignalBatch(signals: signals, clientUser: clientUser, sessionID: sessionID)
    }

    static func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// The encoded body as the server would parse it. Asserting against the
    /// Swift struct would pass even if `CodingKeys` renamed every field.
    static func elements(
        for batch: SignalBatch = TelemetryDeckFixture.batch(),
        configuration: TelemetryDeckConfiguration = TelemetryDeckFixture.configuration()
    ) throws -> [[String: Any]] {
        let data = try body(for: batch, configuration: configuration)
        let json = try JSONSerialization.jsonObject(with: data)
        return try #require(json as? [[String: Any]], "v2 ingest takes a JSON array of signal objects")
    }

    static func element(
        for signal: Signal,
        configuration: TelemetryDeckConfiguration = TelemetryDeckFixture.configuration()
    ) throws -> [String: Any] {
        let elements = try elements(for: batch(signals: [signal]), configuration: configuration)
        return try #require(elements.first)
    }

    static func body(
        for batch: SignalBatch = TelemetryDeckFixture.batch(),
        configuration: TelemetryDeckConfiguration = TelemetryDeckFixture.configuration()
    ) throws -> Data {
        let request = try transport(configuration: configuration).makeRequest(for: batch)
        return try #require(request.httpBody)
    }

    static func bodyText(
        for batch: SignalBatch = TelemetryDeckFixture.batch(),
        configuration: TelemetryDeckConfiguration = TelemetryDeckFixture.configuration()
    ) throws -> String {
        let data = try body(for: batch, configuration: configuration)
        return try #require(String(data: data, encoding: .utf8))
    }

    static func string(_ value: Any?, _ field: String) throws -> String {
        try #require(value as? String, "\(field) must be a JSON string")
    }
}

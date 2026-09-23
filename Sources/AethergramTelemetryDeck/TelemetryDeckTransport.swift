import AethergramCore
import Foundation
import os

internal import CryptoKit

/// `SignalTransport` over TelemetryDeck's documented v2 ingest API.
///
/// The whole vendor surface, and nothing else: it does not decide when to
/// send, what to retry, or whether consent exists, and it persists nothing.
/// Deleting this file leaves `AethergramCore` compiling, which is the test of
/// whether the boundary is real.
public struct TelemetryDeckTransport: SignalTransport {
    // MARK: Lifecycle

    /// - Parameter logSubsystem: The host's logging subsystem. Outcomes are the
    ///   core's to log; what this logs is the one fact only the adapter knows —
    ///   which ingest partition a build is posting to.
    /// - Parameter session: Any session but a background one. Sends are async
    ///   data tasks, which a background session refuses by raising an
    ///   exception that aborts the host.
    /// - Precondition: `session` has no background identifier. Checked here so
    ///   the trap lands at construction rather than at the first send.
    public init(
        configuration: TelemetryDeckConfiguration,
        logSubsystem: String,
        session: URLSession = .shared
    ) {
        precondition(
            session.configuration.identifier == nil,
            "TelemetryDeckTransport cannot send over a background URLSession"
        )
        self.configuration = configuration
        self.session = session
        logger = Logger(subsystem: logSubsystem, category: "aethergram-telemetrydeck")
    }

    // MARK: Public

    /// Posts the batch as one request and maps the reply:
    ///
    /// | Reply | Outcome |
    /// |---|---|
    /// | 2xx | `delivered` |
    /// | 400, 401, 403, 404, 413, 422, 501, 505 | `permanent` |
    /// | Any other status, including 429 and other 5xx | `retryable` |
    /// | A response that is not HTTP | `retryable` |
    /// | A thrown error, cancellation included | `retryable` |
    /// | A batch that cannot be encoded | `permanent` |
    ///
    /// Cancellation reaches the request through `URLSession`, so an erase
    /// that cancels the drain stops a send still in flight.
    public func send(_ batch: SignalBatch) async -> TransportOutcome {
        let request: URLRequest
        do {
            request = try makeRequest(for: batch)
        } catch {
            // Defensive: `Signal` admits no value the encoder refuses, so this
            // is unreachable today, and a batch that ever is unencodable will
            // not become encodable on a retry.
            return .permanent(reason: "encode-failed")
        }
        // Which partition this build posts to, on every batch and in every
        // configuration. Carries no payload, so it is safe in a shipping build,
        // and it is the only channel that can show a Release build sending
        // `isTestMode` false.
        logger.info(
            "post count=\(batch.signals.count) testMode=\(configuration.isTestMode, privacy: .public)"
        )
        do {
            let (_, response) = try await session.data(for: request)
            return Self.outcome(for: response)
        } catch let error as URLError {
            return .retryable(reason: "urlerror-\(error.code.rawValue)")
        } catch {
            return .retryable(reason: "transport-error")
        }
    }

    // MARK: Internal

    /// Status handling mirrors the SDK's own table so the swap does not change
    /// which failures cost signals. The vendor's ingest API documents no status
    /// contract; 400, 401, 403, 404, 413, 422, 501, and 505 drop the batch
    /// because the SDK's own `disposition()` treats them as permanent —
    /// everything else, including 429, other 5xx, and no response, stays
    /// queued for the core's backoff.
    static func outcome(for response: URLResponse) -> TransportOutcome {
        guard let http = response as? HTTPURLResponse else { return .retryable(reason: "non-http-response") }
        if (200 ... 299).contains(http.statusCode) { return .delivered }
        switch http.statusCode {
        case 400, 401, 403, 404, 413, 422, 501, 505:
            return .permanent(reason: "http-\(http.statusCode)")
        default:
            return .retryable(reason: "http-\(http.statusCode)")
        }
    }

    func makeRequest(for batch: SignalBatch) throws -> URLRequest {
        var request = URLRequest(url: configuration.ingestURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(bodies(for: batch))
        return request
    }

    func bodies(for batch: SignalBatch) -> [TelemetryDeckSignalBody] {
        // Hashed on the client, then hashed and salted again server-side. The
        // salt stays the SDK's default so an install keeps the same user hash
        // across the transport swap.
        let clientUser = Self.sha256(batch.clientUser + configuration.salt)
        return batch.signals.map { signal in
            TelemetryDeckSignalBody(
                receivedAt: signal.recordedAt,
                appID: configuration.appID,
                clientUser: clientUser,
                sessionID: signal.sessionID,
                type: TelemetryDeckWireNames.signalName(for: signal.name),
                floatValue: signal.floatValue,
                payload: TelemetryDeckWireNames.payload(from: signal.parameters),
                isTestMode: configuration.isTestMode ? "true" : "false"
            )
        }
    }

    // MARK: Private

    /// The vendor's ingest parses this exact format; ISO8601 with fractional
    /// seconds is rejected, so the formatter is pinned rather than defaulted.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        encoder.dateEncodingStrategy = .formatted(formatter)
        return encoder
    }()

    private let configuration: TelemetryDeckConfiguration
    private let session: URLSession
    private let logger: Logger

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One element of the v2 ingest array. Field names are the vendor's, spelled
/// exactly, because they are the wire contract.
///
/// The encoder is written out rather than synthesised. Synthesis would produce
/// the same bytes, but it leaves eight stored properties with no readable use
/// site, which is indistinguishable from eight dead fields; spelling the
/// contract makes it reviewable and keeps the `floatValue` omission a decision
/// rather than a side effect of `encodeIfPresent`.
struct TelemetryDeckSignalBody: Encodable {
    // MARK: Internal

    let receivedAt: Date
    let appID: String
    let clientUser: String
    let sessionID: String
    let type: String
    let floatValue: Double?
    let payload: [String: String]
    let isTestMode: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(receivedAt, forKey: .receivedAt)
        try container.encode(appID, forKey: .appID)
        try container.encode(clientUser, forKey: .clientUser)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(type, forKey: .type)
        // Omitted rather than sent as null: the vendor treats an absent
        // `floatValue` as "this signal has no measure", and a null is a decode
        // error rather than the same thing.
        try container.encodeIfPresent(floatValue, forKey: .floatValue)
        try container.encode(payload, forKey: .payload)
        try container.encode(isTestMode, forKey: .isTestMode)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case receivedAt
        case appID
        case clientUser
        case sessionID
        case type
        case floatValue
        case payload
        case isTestMode
    }
}

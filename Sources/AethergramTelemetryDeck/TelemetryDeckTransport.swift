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
    public init(
        configuration: TelemetryDeckConfiguration,
        logSubsystem: String,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        logger = Logger(subsystem: logSubsystem, category: "aethergram-telemetrydeck")
    }

    // MARK: Public

    public func send(_ batch: SignalBatch) async -> TransportOutcome {
        let request: URLRequest
        do {
            request = try makeRequest(for: batch)
        } catch {
            // An unencodable batch will not become encodable on a retry.
            return .permanent(reason: "encode-failed")
        }
        // Which partition this build posts to, on every batch and in every
        // configuration. Carries no payload, so it is safe in a shipping build,
        // and it is the only channel that can show a Release build sending
        // `isTestMode` false — the envelope dump below compiles out there.
        logger.info(
            "post count=\(batch.signals.count) testMode=\(configuration.isTestMode, privacy: .public)"
        )
        #if DEBUG
            Self.recordEnvelopeForInspection(request.httpBody, logger: logger)
        #endif
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
    /// which failures cost signals. Codes the server uses to say "this request
    /// is wrong" drop the batch; everything else — 429, 5xx, no response —
    /// stays queued for the core's backoff.
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
                sessionID: batch.sessionID,
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

    #if DEBUG
        /// Appends each outgoing body to an NDJSON file in the host's caches
        /// directory, one envelope per line.
        ///
        /// A file rather than a log line because `os_log` truncates a dynamic
        /// string at roughly a kilobyte and these bodies run past that, so the
        /// logged form silently loses the tail — which is exactly the part a
        /// payload audit needs. Caches, so the OS may evict it and nothing
        /// depends on it surviving. Compiled out of any shipping build.
        private static func recordEnvelopeForInspection(_ body: Data?, logger: Logger) {
            guard let body else { return }
            guard let directory = try? FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ) else { return }
            let url = directory.appendingPathComponent("aethergram-debug-envelopes.ndjson")
            var line = body
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: [.atomic])
            }
            logger.debug("post envelope recorded bytes=\(body.count)")
        }
    #endif

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

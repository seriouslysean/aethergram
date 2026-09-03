import Foundation

/// One recorded event on its way to a transport.
///
/// Vendor-neutral by construction: `name` is the consumer's own vocabulary and
/// `parameters` its own keys. Neither the queue nor an adapter interprets
/// either one; an adapter may rename them on the wire, never rewrite them.
///
/// `Codable` because the queue is durable — an extension is killed between the
/// record and the send often enough that in-memory-only would lose signals.
public struct Signal: Codable, Equatable, Sendable {
    // MARK: Lifecycle

    public init(
        name: String,
        parameters: [String: String] = [:],
        floatValue: Double? = nil,
        recordedAt: Date
    ) {
        self.name = name
        self.parameters = parameters
        self.floatValue = floatValue
        self.recordedAt = recordedAt
    }

    // MARK: Public

    /// Event name as the consumer wrote it, before any prefix or wire mapping.
    public let name: String

    /// String-typed metadata. Numeric values needing aggregation belong in
    /// `floatValue`; every transport this package targets stringifies the rest.
    public let parameters: [String: String]

    /// The one numeric field a dashboard can aggregate across signals.
    public let floatValue: Double?

    /// When the consumer recorded it, not when it was transmitted. A batch that
    /// waits out a backoff still reports the moment the event happened.
    public let recordedAt: Date
}

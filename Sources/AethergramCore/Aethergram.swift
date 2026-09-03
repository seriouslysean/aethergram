import Foundation

/// What the package calls itself on a signal it wrote.
///
/// A dashboard that spans the transport cutover holds rows the vendor's SDK
/// sent and rows this package sent, under the same field names by design.
/// Stamping the identity is what keeps them separable: without it a payload
/// that lost a field reads as a data outage rather than a transport swap.
enum Aethergram {
    static let name = "Aethergram"

    /// The payload contract's version, not the app's. It bumps when the set of
    /// fields the package attaches changes, or when the form one of them takes
    /// changes; `app.version` answers which build a signal came from, this
    /// answers which shape it arrived in. Starts at 1.0.0, the shape the
    /// package shipped with.
    static let version = "1.0.0"

    /// The pair as one grouping key, in the form the vendor's own SDK sent it.
    /// Derived rather than written a second time, so a version bump cannot
    /// leave half the identity behind.
    static let nameAndVersion = "\(name) \(version)"
}

import Foundation

/// What the package calls itself on a signal it wrote.
///
/// A dashboard that spans the transport cutover holds rows the vendor's SDK
/// sent and rows this package sent, under the same field names by design.
/// Stamping the identity is what keeps them separable: without it a payload
/// that lost a field reads as a data outage rather than a transport swap.
enum Aethergram {
    static let name = "Aethergram"

    /// The package's release version, not the app's: `app.version` answers
    /// which build a signal came from, this answers which release wrote it.
    /// It is the version in `CHANGELOG.md`'s top heading, and
    /// `Scripts/check-version-stamp.sh` refuses a tree where the two differ,
    /// so it is set in the change that prepares a release. STABILITY.md lists
    /// what the releases before 2.1.0 stamped, when this was a separate
    /// payload version.
    static let version = "2.1.0"

    /// The pair as one grouping key, in the form the vendor's own SDK sent it.
    /// Derived rather than written a second time, so a version bump cannot
    /// leave half the identity behind.
    static let nameAndVersion = "\(name) \(version)"

    /// The identity as payload fields. It lives here rather than in
    /// `EnvironmentSnapshot`, because the recorder stamps it on every signal
    /// independently of the authored payload — a host that overrides the
    /// environment must not be able to drop it.
    static let parameters: [String: String] = [
        PayloadKey.sdkName: name,
        PayloadKey.sdkVersion: version,
        PayloadKey.sdkNameAndVersion: nameAndVersion
    ]
}

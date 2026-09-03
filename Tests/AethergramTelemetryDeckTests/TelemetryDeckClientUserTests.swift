import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// The identifier the dashboard buckets users by.
///
/// The SDK computes it as `CryptoHashing.sha256(string:salt:)`, which is
/// `SHA256.hash(data: (string + salt).utf8)` rendered `%02x`. Getting this
/// wrong does not fail: it silently re-buckets every existing install as new,
/// which is why the digests below are literals computed outside Swift rather
/// than recomputed with the same call the adapter makes.
@Suite("TelemetryDeck client user", .tags(.wireFormat))
struct TelemetryDeckClientUserTests {
    /// `printf 'abc' | shasum -a 256`
    static let digestOfABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    /// `printf 'abcpepper' | shasum -a 256`
    static let digestOfABCPepper = "e5c5d287a03c5b390a364c2ef137aa2d1fb6a78291cec2276b27b054c2012b22"

    /// `printf 'install-42' | shasum -a 256`
    static let digestOfInstall42 = "cd32fd434903ec100c9deb33b291ad7dddce4fd32e3a13e12d1a54bc5a68d517"

    @Test("clientUser is the lowercase hex SHA256 of the identifier")
    func clientUserIsHexDigest() throws {
        let batch = TelemetryDeckFixture.batch(clientUser: "install-42")

        let element = try #require(try TelemetryDeckFixture.elements(for: batch).first)

        #expect(try TelemetryDeckFixture.string(element["clientUser"], "clientUser") == Self.digestOfInstall42)
    }

    /// The default salt is empty, which is the SDK's default. Any other value
    /// would hash the same install to a different bucket and orphan its
    /// history, so the continuity claim is tested as `sha256(user)` alone.
    @Test("The default empty salt preserves an existing install's hash")
    func defaultSaltMatchesTheSDKHash() throws {
        let configuration = TelemetryDeckFixture.configuration()
        #expect(configuration.salt.isEmpty)

        let element = try #require(
            try TelemetryDeckFixture.elements(
                for: TelemetryDeckFixture.batch(clientUser: "abc"),
                configuration: configuration
            ).first
        )

        #expect(try TelemetryDeckFixture.string(element["clientUser"], "clientUser") == Self.digestOfABC)
    }

    @Test("A salt is appended before hashing")
    func saltIsAppendedBeforeHashing() throws {
        let configuration = TelemetryDeckFixture.configuration(salt: "pepper")

        let element = try #require(
            try TelemetryDeckFixture.elements(
                for: TelemetryDeckFixture.batch(clientUser: "abc"),
                configuration: configuration
            ).first
        )

        let hashed = try TelemetryDeckFixture.string(element["clientUser"], "clientUser")
        #expect(hashed == Self.digestOfABCPepper)
        #expect(hashed != Self.digestOfABC, "a non-empty salt must re-bucket, which is why the default stays empty")
    }

    @Test("The digest is 64 lowercase hex characters")
    func digestShape() throws {
        let element = try #require(try TelemetryDeckFixture.elements().first)

        let hashed = try TelemetryDeckFixture.string(element["clientUser"], "clientUser")
        #expect(hashed.count == 64)
        #expect(hashed.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("The raw identifier never reaches the wire")
    func rawIdentifierIsNotSent() throws {
        let batch = TelemetryDeckFixture.batch(clientUser: "install-42")

        let text = try TelemetryDeckFixture.bodyText(for: batch)

        #expect(!text.contains("install-42"))
        #expect(text.contains(Self.digestOfInstall42))
    }

    @Test("One hash covers the whole batch")
    func hashIsComputedOncePerBatch() throws {
        let signals = [
            TelemetryDeckFixture.signal(),
            TelemetryDeckFixture.signal(name: "Example.Turn.sent"),
            TelemetryDeckFixture.signal(name: "Example.Game.finished")
        ]
        let batch = TelemetryDeckFixture.batch(signals: signals, clientUser: "install-42")

        let elements = try TelemetryDeckFixture.elements(for: batch)

        let hashes = try elements.map { try TelemetryDeckFixture.string($0["clientUser"], "clientUser") }
        #expect(hashes == Array(repeating: Self.digestOfInstall42, count: 3))
    }
}

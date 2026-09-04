import AethergramCore
@testable import AethergramTelemetryDeck
import Foundation
import AethergramTestSupport
import Testing

/// The shape of the encoded body, read back the way the server reads it.
///
/// Every assertion here decodes `httpBody` with `JSONSerialization` rather than
/// inspecting `TelemetryDeckSignalBody`, because a `CodingKeys` change would
/// keep the struct assertions green while renaming every field on the wire.
@Suite("TelemetryDeck body", .tags(.wireFormat))
struct TelemetryDeckBodyTests {
    /// One partition-mapping row: a name for the failure message, the snapshot
    /// under test, and the expected `isTestMode` reading.
    struct PartitionRow {
        let name: String
        let snapshot: EnvironmentSnapshot
        let expectedIsTestMode: Bool
    }

    /// The vendor's `SignalPostBody` field names, spelled here so the test is
    /// the contract rather than a mirror of the adapter's struct.
    static let vendorFields: Set<String> = [
        "receivedAt",
        "appID",
        "clientUser",
        "sessionID",
        "type",
        "floatValue",
        "payload",
        "isTestMode"
    ]

    /// Minimal `EnvironmentSnapshot` construction for the partition-mapping
    /// suite: only `channel` matters to `testPartition(for:)`, so every other
    /// field is a placeholder.
    static func snapshot(channel: RunContextChannel = .dev) -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            appVersion: "1.0",
            appBuild: "1",
            modelName: "iPhone",
            platform: "iOS",
            systemVersion: "18.0",
            systemMajorMinorVersion: "18.0",
            channel: channel,
            region: "US",
            language: "en"
        )
    }

    @Test("The body is a JSON array with one element per signal")
    func bodyIsAnArrayOfSignals() throws {
        let signals = [
            TelemetryDeckFixture.signal(name: "Example.Game.started"),
            TelemetryDeckFixture.signal(name: "Example.Game.finished"),
            TelemetryDeckFixture.signal(name: "Example.Turn.sent")
        ]

        let elements = try TelemetryDeckFixture.elements(for: TelemetryDeckFixture.batch(signals: signals))

        #expect(elements.count == 3)
        let types = try elements.map { try TelemetryDeckFixture.string($0["type"], "type") }
        #expect(types == ["Example.Game.started", "Example.Game.finished", "Example.Turn.sent"])
    }

    @Test("An empty batch encodes as an empty array, not null")
    func emptyBatchEncodesAsEmptyArray() throws {
        let elements = try TelemetryDeckFixture.elements(for: TelemetryDeckFixture.batch(signals: []))

        #expect(elements.isEmpty)
        #expect(try TelemetryDeckFixture.bodyText(for: TelemetryDeckFixture.batch(signals: [])) == "[]")
    }

    @Test("Each element carries exactly the vendor's field names")
    func elementFieldNames() throws {
        let element = try TelemetryDeckFixture.element(for: TelemetryDeckFixture.signal(floatValue: 1))

        #expect(Set(element.keys) == Self.vendorFields)
    }

    @Test("Per-batch fields ride every element")
    func batchFieldsRideEveryElement() throws {
        let batch = SignalBatch(
            signals: [TelemetryDeckFixture.signal(), TelemetryDeckFixture.signal(name: "Example.Turn.sent")],
            clientUser: "abc",
            sessionID: "session-7"
        )
        let configuration = TelemetryDeckFixture.configuration(appID: "app-42")

        let elements = try TelemetryDeckFixture.elements(for: batch, configuration: configuration)

        for element in elements {
            #expect(try TelemetryDeckFixture.string(element["appID"], "appID") == "app-42")
            #expect(try TelemetryDeckFixture.string(element["sessionID"], "sessionID") == "session-7")
        }
    }

    /// The vendor's decoder is `.formatted("yyyy-MM-dd'T'HH:mm:ssZ")`, which
    /// rejects the fractional-seconds ISO8601 form a default `JSONEncoder`
    /// date strategy would not produce either. Both wrong answers land as a
    /// 4xx the adapter drops, so the exact string is the assertion.
    @Test("receivedAt is the vendor's second-precision format")
    func receivedAtFormat() throws {
        let element = try TelemetryDeckFixture.element(for: TelemetryDeckFixture.signal())

        #expect(try TelemetryDeckFixture.string(element["receivedAt"], "receivedAt")
            == TelemetryDeckFixture.instantOnTheWire)
        #expect(try TelemetryDeckFixture.string(element["receivedAt"], "receivedAt") == "2023-11-14T22:13:20+0000")
    }

    @Test("receivedAt is the recording instant, not the encoding instant")
    func receivedAtIsPerSignal() throws {
        let earlier = TelemetryDeckFixture.signal(recordedAt: Date(timeIntervalSince1970: 1_000_000_000))
        let later = TelemetryDeckFixture.signal(name: "Example.Turn.sent")

        let elements = try TelemetryDeckFixture.elements(for: TelemetryDeckFixture.batch(signals: [earlier, later]))

        let stamps = try elements.map { try TelemetryDeckFixture.string($0["receivedAt"], "receivedAt") }
        #expect(stamps == ["2001-09-09T01:46:40+0000", TelemetryDeckFixture.instantOnTheWire])
    }

    /// The vendor types this field `String`, not `Bool`. A JSON boolean is a
    /// decode failure server-side, so the raw bytes are checked as well as the
    /// parsed value.
    @Test("isTestMode is a JSON string", arguments: [true, false])
    func isTestModeIsAString(isTestMode: Bool) throws {
        let configuration = TelemetryDeckFixture.configuration(isTestMode: isTestMode)
        let batch = TelemetryDeckFixture.batch()
        let expected = isTestMode ? "true" : "false"

        let element = try #require(
            try TelemetryDeckFixture.elements(for: batch, configuration: configuration).first
        )
        let text = try TelemetryDeckFixture.bodyText(for: batch, configuration: configuration)

        #expect(try TelemetryDeckFixture.string(element["isTestMode"], "isTestMode") == expected)
        // `NSNumber as? Bool` succeeds by bridging, so a parsed-value check
        // cannot tell a JSON boolean from the string the vendor requires. The
        // raw bytes are the only assertion that can fail here.
        #expect(text.contains("\"isTestMode\":\"\(expected)\""))
        #expect(!text.contains("\"isTestMode\":\(expected)"))
    }

    /// The vendor's SDK derived `testMode` from `DEBUG` alone, which let a
    /// Release build on the simulator, a Release run on a developer device,
    /// and every TestFlight install post to the live partition. Only an App
    /// Store install may land in live figures; every other row here reads
    /// test, whatever the vendor's own default would have said.
    @Test(
        "Only an App Store install reads the live partition",
        arguments: [
            PartitionRow(name: "dev channel", snapshot: Self.snapshot(channel: .dev), expectedIsTestMode: true),
            PartitionRow(name: "beta channel", snapshot: Self.snapshot(channel: .beta), expectedIsTestMode: true),
            PartitionRow(name: "store channel", snapshot: Self.snapshot(channel: .store), expectedIsTestMode: false)
        ]
    )
    func partitionMatchesTheDistributionChannel(row: PartitionRow) throws {
        let isTestMode = TelemetryDeckConfiguration.testPartition(for: row.snapshot)
        #expect(
            isTestMode == row.expectedIsTestMode,
            "\(row.name) should read isTestMode == \(row.expectedIsTestMode)"
        )

        let configuration = TelemetryDeckFixture.configuration(isTestMode: isTestMode)
        let element = try #require(
            try TelemetryDeckFixture.elements(for: TelemetryDeckFixture.batch(), configuration: configuration).first
        )
        let expected = row.expectedIsTestMode ? "true" : "false"
        #expect(try TelemetryDeckFixture.string(element["isTestMode"], "isTestMode") == expected)
    }

    /// Synthesised `Encodable` for `Double?` emits `encodeIfPresent`, so a nil
    /// `floatValue` drops the key rather than sending `null`. The vendor's own
    /// `SignalPostBody` has the identical synthesised conformance, so this is
    /// the same body the SDK sent.
    @Test("A nil floatValue omits the key rather than sending null")
    func nilFloatValueOmitsKey() throws {
        let batch = TelemetryDeckFixture.batch(signals: [TelemetryDeckFixture.signal(floatValue: nil)])
        let element = try #require(try TelemetryDeckFixture.elements(for: batch).first)
        let text = try TelemetryDeckFixture.bodyText(for: batch)

        #expect(element["floatValue"] == nil)
        #expect(Set(element.keys) == Self.vendorFields.subtracting(["floatValue"]))
        #expect(!text.contains("floatValue"))
    }

    @Test("A present floatValue rides as a JSON number")
    func floatValueEncodesAsNumber() throws {
        let element = try TelemetryDeckFixture.element(for: TelemetryDeckFixture.signal(floatValue: 4.99))

        let value = try #require(element["floatValue"] as? Double)
        #expect(value == 4.99)
    }

    @Test("An empty parameter set encodes as an empty payload object")
    func emptyPayloadEncodesAsObject() throws {
        let element = try TelemetryDeckFixture.element(for: TelemetryDeckFixture.signal(parameters: [:]))

        let payload = try #require(element["payload"] as? [String: String])
        #expect(payload.isEmpty)
    }

    @Test("Payload values stay strings")
    func payloadValuesStayStrings() throws {
        let signal = TelemetryDeckFixture.signal(parameters: [
            PayloadKey.retentionTotalSessionsCount: "12",
            PayloadKey.runContextChannel: RunContextChannel.dev.rawValue
        ])

        let element = try TelemetryDeckFixture.element(for: signal)

        let payload = try #require(element["payload"] as? [String: String])
        #expect(payload["TelemetryDeck.Retention.totalSessionsCount"] == "12")
        #expect(payload["TelemetryDeck.RunContext.channel"] == "dev")
    }
}

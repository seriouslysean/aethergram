// swift-tools-version: 6.2
import PackageDescription

/// Every target compiles under the same semantics: the language mode is pinned
/// rather than inherited, so a host that builds with different settings cannot
/// change what this package means.
let aethergramSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "Aethergram",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // The umbrella is the only product. Sub-targets are reached through
        // `@_exported import` re-exports, so a host imports one module and the
        // boundary between core and adapter stays one-directional.
        .library(name: "Aethergram", targets: ["Aethergram"])
    ],
    targets: [
        // Knows nothing about any vendor. Deleting the adapter target below
        // leaves this one compiling, which is the test of that claim.
        .target(
            name: "AethergramCore",
            swiftSettings: aethergramSwiftSettings
        ),
        // The only module that knows a vendor exists.
        .target(
            name: "AethergramTelemetryDeck",
            dependencies: ["AethergramCore"],
            swiftSettings: aethergramSwiftSettings
        ),
        .target(
            name: "Aethergram",
            dependencies: ["AethergramCore", "AethergramTelemetryDeck"],
            swiftSettings: aethergramSwiftSettings
        ),
        // Tag taxonomy and the temp-directory trait. A plain target rather than
        // a test target so both suites can share it, and it lives under Tests/
        // so the Testing framework it imports stays out of the shipped product.
        .target(
            name: "AethergramTestSupport",
            path: "Tests/AethergramTestSupport",
            swiftSettings: aethergramSwiftSettings
        ),
        // Test targets depend on the modules under test, never on the umbrella:
        // a test that needed the umbrella would mean the layer under it had
        // grown a dependency it is not allowed to have.
        .testTarget(
            name: "AethergramCoreTests",
            dependencies: ["AethergramCore", "AethergramTestSupport"],
            swiftSettings: aethergramSwiftSettings
        ),
        .testTarget(
            name: "AethergramTelemetryDeckTests",
            dependencies: ["AethergramCore", "AethergramTelemetryDeck", "AethergramTestSupport"],
            swiftSettings: aethergramSwiftSettings
        )
    ]
)

// swift-tools-version: 6.3
import Foundation
import PackageDescription

// A path dependency's identity is its directory's name, which differs between clones, so it is
// read from where this manifest sits rather than spelled.
let aethergramIdentity = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../..")
    .standardizedFileURL
    .lastPathComponent

// A host as a host builds one: it depends on the umbrella product alone, and compiles in language
// mode 6 with none of the upcoming-feature flags the package itself sets, so whatever the package
// publishes has to hold up under a host's defaults rather than its own.
let package = Package(
    name: "ConsumerHost",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [
        .package(path: "../../..")
    ],
    targets: [
        // Extension-safe: the run-checks gate builds it for iOS release with -application-extension.
        .target(
            name: "ConsumerHostExtension",
            dependencies: [.product(name: "Aethergram", package: aethergramIdentity)]
        ),
        // The app pattern. Its UIKit binding calls `UIApplication.shared`, which an extension may
        // not, so this target stays out of the extension-safe build.
        .target(
            name: "ConsumerHostApp",
            dependencies: ["ConsumerHostExtension"]
        ),
        .testTarget(
            name: "ConsumerHostTests",
            dependencies: ["ConsumerHostExtension", "ConsumerHostApp"]
        )
    ]
)

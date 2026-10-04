// swift-tools-version: 6.1
//
// MacReplica is built with Swift Package Manager so it can be compiled,
// tested and packaged with the Xcode Command Line Tools alone.
// Xcode opens this file directly as a project (File > Open > Package.swift).

import Foundation
import PackageDescription

// With only the Xcode Command Line Tools installed, SwiftPM's default build
// system occasionally loses the search path for the Swift Testing macros on
// incremental builds. `scripts/test.sh` sets MACREPLICA_CLT_TESTING=1 to add it
// explicitly; builds with full Xcode (and CI) do not need this.
let testSwiftSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["MACREPLICA_CLT_TESTING"] == "1"
    ? [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
    : []

let package = Package(
    name: "MacReplica",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacReplica", targets: ["MacReplica"]),
        .executable(name: "MacReplicaAskpass", targets: ["MacReplicaAskpass"]),
        .library(name: "MacReplicaCore", targets: ["MacReplicaCore"]),
    ],
    targets: [
        .target(
            name: "MacReplicaCore",
            resources: [
                .copy("Resources/Localization")
            ]
        ),
        .executableTarget(
            name: "MacReplica",
            dependencies: ["MacReplicaCore"]
        ),
        .executableTarget(
            name: "MacReplicaAskpass"
        ),
        // Development only: builds sandboxed simulation environments for tests
        // and on-screen validation. Not part of the shipped app.
        .target(
            name: "MacReplicaTestSupport",
            dependencies: ["MacReplicaCore"]
        ),
        .executableTarget(
            name: "MacReplicaSimulator",
            dependencies: ["MacReplicaCore", "MacReplicaTestSupport"]
        ),
        .testTarget(
            name: "MacReplicaCoreTests",
            // The askpass helper is built for the tests that run it against MacReplica's password channel.
            dependencies: ["MacReplicaCore", "MacReplicaTestSupport", "MacReplicaAskpass"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: testSwiftSettings
        ),
    ]
)

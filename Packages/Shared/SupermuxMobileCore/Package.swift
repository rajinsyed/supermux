// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupermuxMobileCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SupermuxMobileCore",
            targets: ["SupermuxMobileCore"]
        ),
    ],
    dependencies: [
        // CmxTailscalePeerAddress: the exact Tailscale peer ranges the route
        // classifier checks before LAN.
        .package(path: "../CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "SupermuxMobileCore",
            dependencies: ["CMUXMobileCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SupermuxMobileCoreTests",
            dependencies: ["SupermuxMobileCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

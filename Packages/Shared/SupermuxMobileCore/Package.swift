// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupermuxMobileCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SupermuxMobileCore",
            targets: ["SupermuxMobileCore"]
        ),
    ],
    targets: [
        .target(
            name: "SupermuxMobileCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SupermuxMobileCoreTests",
            dependencies: ["SupermuxMobileCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

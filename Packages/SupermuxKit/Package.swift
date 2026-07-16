// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupermuxKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SupermuxKit",
            targets: ["SupermuxKit"]
        ),
    ],
    dependencies: [
        // Upstream relocated packages under Packages/macOS/ and folded the old
        // CmuxProcess micro-package into CmuxFoundation (cmux #6356).
        .package(path: "../macOS/CmuxFoundation"),
        .package(path: "../macOS/CmuxGit"),
        // Shared wire contract with the iOS companion app (mobile.supermux.* DTOs).
        .package(path: "../Shared/SupermuxMobileCore"),
    ],
    targets: [
        .target(
            name: "SupermuxKit",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxGit", package: "CmuxGit"),
                .product(name: "SupermuxMobileCore", package: "SupermuxMobileCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "SupermuxKitTests",
            dependencies: [
                "SupermuxKit",
                .product(name: "SupermuxMobileCore", package: "SupermuxMobileCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

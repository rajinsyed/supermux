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
        // Claude Code stream-json protocol model shared with the iOS harness UI.
        .package(path: "../Shared/SupermuxClaudeHarness"),
        // The shared zeron design system (tokens, metrics, fonts, icons, and
        // the platform-agnostic chat-pane views). macOS mounts it; iOS mounts
        // the same package from SupermuxMobileUI.
        .package(path: "../Shared/SupermuxZeronUI"),
    ],
    targets: [
        .target(
            name: "SupermuxKit",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxGit", package: "CmuxGit"),
                .product(name: "SupermuxMobileCore", package: "SupermuxMobileCore"),
                .product(name: "SupermuxClaudeHarness", package: "SupermuxClaudeHarness"),
                .product(name: "SupermuxZeronUI", package: "SupermuxZeronUI"),
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
                .product(name: "SupermuxClaudeHarness", package: "SupermuxClaudeHarness"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

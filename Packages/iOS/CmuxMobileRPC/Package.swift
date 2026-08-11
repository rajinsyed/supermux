// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileRPC",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileRPC",
            targets: ["CmuxMobileRPC"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
        // SUPERMUX:begin notification-feed-project-wire
        // The shared notification-project wire type, decoded from the Mac's
        // additive `supermux_project` field on each feed row.
        .package(path: "../../Shared/SupermuxMobileCore"),
        // SUPERMUX:end notification-feed-project-wire
    ],
    targets: [
        .target(
            name: "CmuxMobileRPC",
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
                // SUPERMUX:begin notification-feed-project-wire
                "SupermuxMobileCore",
                // SUPERMUX:end notification-feed-project-wire
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileRPCTests",
            dependencies: [
                "CmuxMobileRPC",
                "CMUXMobileCore",
                "CmuxMobileShellModel",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

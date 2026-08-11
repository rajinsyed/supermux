// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileShellModel",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileShellModel",
            targets: ["CmuxMobileShellModel"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        // SUPERMUX:begin notification-feed-project-wire
        // The shared notification-project snapshot carried on each feed item.
        .package(path: "../../Shared/SupermuxMobileCore"),
        // SUPERMUX:end notification-feed-project-wire
    ],
    targets: [
        .target(
            name: "CmuxMobileShellModel",
            dependencies: [
                "CMUXMobileCore",
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
            name: "CmuxMobileShellModelTests",
            dependencies: [
                "CmuxMobileShellModel",
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
    ]
)

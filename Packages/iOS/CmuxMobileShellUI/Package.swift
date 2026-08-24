// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileShellUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "CmuxMobileShellUI",
            targets: ["CmuxMobileShellUI"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxAgentChat"),
        .package(path: "../CmuxAgentChatUI"),
        .package(path: "../../Shared/CmuxAuthRuntime"),
        .package(path: "../CmuxMobileBrowser"),
        .package(path: "../CmuxMobileBrowserStream"),
        .package(path: "../CmuxMobileCamera"),
        .package(path: "../CmuxMobileChanges"),
        .package(path: "../CmuxMobileDiagnostics"),
        .package(path: "../CmuxMobilePairedMac"),
        .package(path: "../CmuxMobileRPC"),
        .package(path: "../CmuxMobileShell"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSimulatorStream"),
        .package(path: "../../Shared/CmuxSimulatorStreamKit"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileTerminal"),
        .package(path: "../CmuxMobileToast"),
        .package(path: "../CmuxMobileTerminalKit"),
        .package(path: "../CmuxMobileWorkspace"),
        // SUPERMUX:begin supermux-mobile-shellui-deps (fork package: Projects section mounted in WorkspaceListView)
        .package(path: "../SupermuxMobileUI"),
        // The shared notification-project type: the feed row derives its
        // project presentation from it, and the row tests build fixtures with it.
        .package(path: "../../Shared/SupermuxMobileCore"),
        // SUPERMUX:end supermux-mobile-shellui-deps
        .package(path: "../../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "CmuxMobileShellUI",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAgentChat",
                "CmuxAgentChatUI",
                "CmuxAuthRuntime",
                "CmuxMobileBrowser",
                "CmuxMobileBrowserStream",
                "CmuxMobileCamera",
                "CmuxMobileChanges",
                "CmuxMobileDiagnostics",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileSimulatorStream",
                "CmuxSimulatorStreamKit",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
                "CmuxMobileToast",
                "CmuxMobileWorkspace",
                // SUPERMUX:begin supermux-mobile-shellui-deps (fork package: Projects section mounted in WorkspaceListView)
                "SupermuxMobileUI",
                "SupermuxMobileCore",
                // SUPERMUX:end supermux-mobile-shellui-deps
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxMobileShellUITests",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAuthRuntime",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShellUI",
                "CmuxAgentChat",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileSimulatorStream",
                "CmuxSimulatorStreamKit",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileToast",
                "CmuxMobileWorkspace",
                // SUPERMUX:begin notification-feed-project-row
                // Test-only: the shared notification-project type the feed-row
                // project coverage constructs fixtures from.
                "SupermuxMobileCore",
                // SUPERMUX:end notification-feed-project-row
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)

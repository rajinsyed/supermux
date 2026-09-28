// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileShell",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileShell",
            targets: ["CmuxMobileShell"]
        ),
        .library(
            name: "CmuxMobileShellReleaseGateSupport",
            targets: ["CmuxMobileShellReleaseGateSupport"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxWorkspacePresence"),
        // SUPERMUX:begin supermux-mobile-selection-sync (typed capability/method constants for bidirectional workspace + terminal selection)
        .package(path: "../../Shared/SupermuxMobileCore"),
        // SUPERMUX:end supermux-mobile-selection-sync
        .package(path: "../../Shared/CmuxAgentChat"),
        .package(path: "../CmuxMobileChanges"),
        .package(path: "../CmuxMobileDiagnostics"),
        .package(path: "../CmuxMobileBrowserStream"),
        .package(path: "../CmuxMobilePairedMac"),
        .package(path: "../CmuxMobileRPC"),
        .package(path: "../CmuxMobileSSH"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileTerminalKit"),
        .package(path: "../CmuxMobileTransport"),
        .package(path: "../CmuxMobileTunnel"),
    ],
    targets: [
        .target(
            name: "CmuxMobileShell",
            dependencies: [
                "CMUXMobileCore",
                "CmuxWorkspacePresence",
                // SUPERMUX:begin supermux-mobile-selection-sync
                "SupermuxMobileCore",
                // SUPERMUX:end supermux-mobile-selection-sync
                "CmuxAgentChat",
                "CmuxMobileChanges",
                "CmuxMobileDiagnostics",
                "CmuxMobileBrowserStream",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileSSH",
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
                "CmuxMobileTerminalKit",
                "CmuxMobileTransport",
                "CmuxMobileTunnel",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "CmuxMobileShellReleaseGateSupport",
            dependencies: [
                "CmuxMobileShell",
                "CMUXMobileCore",
                "CmuxAgentChat",
                "CmuxMobileRPC",
                "CmuxMobileShellModel",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileShellTests",
            dependencies: [
                "CmuxMobileShell",
                "CmuxMobileShellReleaseGateSupport",
                "CMUXMobileCore",
                "CmuxWorkspacePresence",
                "CmuxAgentChat",
                "CmuxMobileBrowserStream",
                "CmuxMobileChanges",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShellModel",
                "CmuxMobileTransport",
                "CmuxMobileTunnel",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

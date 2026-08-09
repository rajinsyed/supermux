// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupermuxMobileUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SupermuxMobileUI",
            targets: ["SupermuxMobileUI"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/SupermuxMobileCore"),
        .package(path: "../SupermuxMobileKit"),
        // Already in the graph via SupermuxMobileKit; declared directly so the
        // shell's `(rpcClient: MobileCoreRPCClient, …)` connection seam can be
        // named in the driver API.
        .package(path: "../CmuxMobileRPC"),
        // Already in the graph via CmuxMobileRPC; declared directly so the
        // hide-filter and the nested-workspace mapping can name
        // `MobileWorkspacePreview` in their public APIs.
        .package(path: "../CmuxMobileShellModel"),
        // Already in the graph transitively; declared directly for the app's
        // gated haptic entry point (`MobileHapticFeedback`), which every
        // cmux-owned haptic must route through.
        .package(path: "../../Shared/CMUXMobileCore"),
        // Already in the graph transitively; declared directly for the shared
        // glass/material modifiers so fork surfaces match the app's chrome.
        .package(path: "../CmuxMobileSupport"),
        // The agent-chat redesign renders upstream's transcript model
        // (`ChatTranscriptRow` and friends) with fork-owned views, so the
        // wire/model package is named directly rather than transitively.
        .package(path: "../../Shared/CmuxAgentChat"),
        // Reuses upstream's keyboard container, transcript table, artifact
        // viewer, and detail sheets; only the row/composer visuals are
        // replaced, through the fenced render seams.
        .package(path: "../CmuxAgentChatUI"),
    ],
    targets: [
        .target(
            name: "SupermuxMobileUI",
            dependencies: [
                "SupermuxMobileCore",
                "SupermuxMobileKit",
                "CmuxMobileRPC",
                "CmuxMobileShellModel",
                "CMUXMobileCore",
                "CmuxMobileSupport",
                "CmuxAgentChat",
                "CmuxAgentChatUI",
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "SupermuxMobileUITests",
            dependencies: [
                "SupermuxMobileUI",
                "SupermuxMobileKit",
                "SupermuxMobileCore",
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

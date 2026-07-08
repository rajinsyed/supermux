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
    ],
    targets: [
        .target(
            name: "SupermuxMobileUI",
            dependencies: [
                "SupermuxMobileCore",
                "SupermuxMobileKit",
                "CmuxMobileRPC",
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
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

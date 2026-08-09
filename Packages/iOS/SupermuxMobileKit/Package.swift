// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupermuxMobileKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SupermuxMobileKit",
            targets: ["SupermuxMobileKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/SupermuxMobileCore"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CmuxMobileRPC"),
    ],
    targets: [
        .target(
            name: "SupermuxMobileKit",
            dependencies: [
                "SupermuxMobileCore",
                "CMUXMobileCore",
                "CmuxMobileRPC",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "SupermuxMobileKitTests",
            dependencies: [
                "SupermuxMobileKit",
                "SupermuxMobileCore",
                "CmuxMobileRPC",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

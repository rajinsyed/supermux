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
        .package(path: "../CmuxProcess"),
        .package(path: "../CmuxGit"),
    ],
    targets: [
        .target(
            name: "SupermuxKit",
            dependencies: [
                .product(name: "CmuxProcess", package: "CmuxProcess"),
                .product(name: "CmuxGit", package: "CmuxGit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "SupermuxKitTests",
            dependencies: ["SupermuxKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

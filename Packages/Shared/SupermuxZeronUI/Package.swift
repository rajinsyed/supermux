// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupermuxZeronUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SupermuxZeronUI",
            targets: ["SupermuxZeronUI"]
        ),
    ],
    dependencies: [
        // The frozen data layer: rows, tool calls, diffs. This is the ONLY
        // dependency the shared zeron UI is allowed to take — it owns the
        // design system, and nothing platform-specific may leak into it.
        .package(path: "../SupermuxClaudeHarness"),
    ],
    targets: [
        .target(
            name: "SupermuxZeronUI",
            dependencies: [
                .product(name: "SupermuxClaudeHarness", package: "SupermuxClaudeHarness"),
            ],
            resources: [
                // `.copy` keeps `Fonts/` a real directory in the bundle.
                // `.process("Resources")` flattens it, which would drop the
                // OFL next to the faces it licenses.
                .copy("Resources/Fonts"),
                // `.process` is what makes Xcode run `actool` over the catalog;
                // a plain `swift build` copies it uncompiled, which is why the
                // template/vector assertions live in an `actool` probe rather
                // than in `swift test` (see SupermuxZeronIconBundle.swift).
                .process("Resources/Icons.xcassets"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "SupermuxZeronUITests",
            dependencies: [
                "SupermuxZeronUI",
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

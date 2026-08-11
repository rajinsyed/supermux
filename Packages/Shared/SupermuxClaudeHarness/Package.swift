// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupermuxClaudeHarness",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SupermuxClaudeHarness",
            targets: ["SupermuxClaudeHarness"]
        ),
    ],
    targets: [
        .target(
            name: "SupermuxClaudeHarness",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SupermuxClaudeHarnessTests",
            dependencies: ["SupermuxClaudeHarness"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

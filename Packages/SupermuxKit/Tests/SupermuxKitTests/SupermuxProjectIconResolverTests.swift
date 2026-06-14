import Foundation
import SupermuxKit
import Testing

struct SupermuxProjectIconResolverTests {
    private let resolver = SupermuxProjectIconResolver()

    /// Creates a unique temporary directory and returns its path; the directory
    /// is removed when `body` finishes.
    private func withTempDirectory(_ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-icon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }

    /// Writes an empty file at `relativePath` under `root`, creating parents.
    private func touch(_ relativePath: String, under root: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    @Test func returnsNilWhenNoIconExists() throws {
        try withTempDirectory { root in
            try touch("README.md", under: root)
            #expect(resolver.resolve(rootPath: root) == nil)
        }
    }

    @Test func findsRootFavicon() throws {
        try withTempDirectory { root in
            try touch("favicon.ico", under: root)
            #expect(resolver.resolve(rootPath: root)?.lastPathComponent == "favicon.ico")
        }
    }

    @Test func findsLogoInPublic() throws {
        try withTempDirectory { root in
            try touch("public/logo.png", under: root)
            let resolved = resolver.resolve(rootPath: root)
            #expect(resolved?.lastPathComponent == "logo.png")
            #expect(resolved?.path.hasPrefix(root) == true)
        }
    }

    @Test func findsNextAppIcon() throws {
        try withTempDirectory { root in
            try touch("src/app/icon.png", under: root)
            #expect(resolver.resolve(rootPath: root)?.lastPathComponent == "icon.png")
        }
    }

    @Test func findsIdeaIcon() throws {
        try withTempDirectory { root in
            try touch(".idea/icon.svg", under: root)
            #expect(resolver.resolve(rootPath: root)?.lastPathComponent == "icon.svg")
        }
    }

    @Test func prefersSvgOverPngAtSameLocation() throws {
        try withTempDirectory { root in
            try touch("favicon.png", under: root)
            try touch("favicon.svg", under: root)
            #expect(resolver.resolve(rootPath: root)?.lastPathComponent == "favicon.svg")
        }
    }

    @Test func prefersRootOverPublic() throws {
        try withTempDirectory { root in
            try touch("public/favicon.svg", under: root)
            try touch("favicon.svg", under: root)
            let resolved = resolver.resolve(rootPath: root)
            #expect(resolved?.path.hasSuffix("/favicon.svg") == true)
            #expect(resolved?.path.contains("/public/") == false)
        }
    }

    @Test func ignoresDirectoryNamedLikeAnIcon() throws {
        try withTempDirectory { root in
            // A directory called `icon.png` must not be mistaken for the icon.
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: root).appendingPathComponent("icon.png"),
                withIntermediateDirectories: true
            )
            try touch("logo.svg", under: root)
            #expect(resolver.resolve(rootPath: root)?.lastPathComponent == "logo.svg")
        }
    }

    @Test func everyCandidatePathIsRelativeAndSafe() {
        for path in SupermuxProjectIconResolver.candidatePaths {
            #expect(!path.hasPrefix("/"))
            #expect(!path.contains(".."))
        }
    }

    // MARK: - resolveAvatar (custom icon override)

    @Test func avatarUsesCustomIconWhenSet() throws {
        try withTempDirectory { root in
            // A repo logo exists, but an explicit custom icon must win over it.
            try touch("favicon.svg", under: root)
            try touch("brand/custom.png", under: root)
            let custom = URL(fileURLWithPath: root).appendingPathComponent("brand/custom.png").path
            let resolved = resolver.resolveAvatar(rootPath: root, customIconPath: custom)
            #expect(resolved?.lastPathComponent == "custom.png")
        }
    }

    @Test func avatarFallsBackToDetectionWhenCustomPathMissing() throws {
        try withTempDirectory { root in
            try touch("logo.svg", under: root)
            let missing = URL(fileURLWithPath: root).appendingPathComponent("nope.png").path
            #expect(resolver.resolveAvatar(rootPath: root, customIconPath: missing)?.lastPathComponent == "logo.svg")
        }
    }

    @Test func avatarFallsBackToDetectionWhenCustomPathIsDirectory() throws {
        try withTempDirectory { root in
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: root).appendingPathComponent("icons"),
                withIntermediateDirectories: true
            )
            try touch("logo.svg", under: root)
            let dir = URL(fileURLWithPath: root).appendingPathComponent("icons").path
            #expect(resolver.resolveAvatar(rootPath: root, customIconPath: dir)?.lastPathComponent == "logo.svg")
        }
    }

    @Test func avatarMatchesDetectionWhenNoCustomPath() throws {
        try withTempDirectory { root in
            try touch("favicon.ico", under: root)
            #expect(resolver.resolveAvatar(rootPath: root, customIconPath: nil)
                == resolver.resolve(rootPath: root))
            #expect(resolver.resolveAvatar(rootPath: root, customIconPath: "  ")?.lastPathComponent == "favicon.ico")
        }
    }
}

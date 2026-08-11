import Foundation
import SupermuxClaudeHarness
import Testing
@testable import SupermuxKit

/// PATH probing, explicit paths, and cmux-wrapper rejection.
struct ClaudeLauncherResolverTests {
    private func makeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func probesPathForClaude() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude", isDirectory: false)
        try makeExecutable(at: claude, contents: "#!/bin/sh\nexit 0\n")

        let resolver = ClaudeLauncherResolver(pathVariable: dir.path)
        let launcher = try resolver.resolve(kind: .claude)
        #expect(launcher.kind == .claude)
        #expect(launcher.executablePath == claude.standardizedFileURL.path)
        #expect(launcher.addsSkipPermissionsFlag)
    }

    @Test func missingLauncherThrowsNotFound() {
        let resolver = ClaudeLauncherResolver(pathVariable: "/nonexistent-dir-xyz")
        #expect(throws: ClaudeLauncherResolver.ResolutionError.notFound(name: "ccx")) {
            _ = try resolver.resolve(kind: .ccx)
        }
    }

    @Test func rejectsCmuxWrapperByContentMarker() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wrapper = dir.appendingPathComponent("claude", isDirectory: false)
        try makeExecutable(
            at: wrapper,
            contents: "#!/bin/sh\n# cmux claude wrapper - injects hooks and session tracking\nexec real-claude \"$@\"\n"
        )

        let resolver = ClaudeLauncherResolver(pathVariable: dir.path)
        // PATH probe skips the wrapper and reports not-found.
        #expect(throws: ClaudeLauncherResolver.ResolutionError.notFound(name: "claude")) {
            _ = try resolver.resolve(kind: .claude)
        }
        // An explicit wrapper path is rejected loudly.
        #expect(throws: ClaudeLauncherResolver.ResolutionError.cmuxWrapperRejected(
            path: wrapper.standardizedFileURL.path
        )) {
            _ = try resolver.resolve(kind: .claude, explicitPath: wrapper.path)
        }
    }

    @Test func probeSkipsWrapperAndFindsRealBinaryLaterInPath() throws {
        let wrapperDir = try temporaryDirectory()
        let realDir = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: wrapperDir)
            try? FileManager.default.removeItem(at: realDir)
        }
        try makeExecutable(
            at: wrapperDir.appendingPathComponent("claude"),
            contents: "#!/bin/sh\n# cmux claude wrapper - injects hooks and session tracking\n"
        )
        let real = realDir.appendingPathComponent("claude")
        try makeExecutable(at: real, contents: "#!/bin/sh\nexit 0\n")

        let resolver = ClaudeLauncherResolver(
            pathVariable: "\(wrapperDir.path):\(realDir.path)"
        )
        let launcher = try resolver.resolve(kind: .claude)
        #expect(launcher.executablePath == real.standardizedFileURL.path)
    }

    @Test func customLauncherRequiresExplicitExecutablePath() throws {
        #expect(throws: ClaudeLauncherResolver.ResolutionError.notFound(name: "custom launcher")) {
            _ = try ClaudeLauncherResolver(pathVariable: "").resolve(kind: .custom)
        }

        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let custom = dir.appendingPathComponent("my-claude", isDirectory: false)
        try makeExecutable(at: custom, contents: "#!/bin/sh\nexit 0\n")
        let launcher = try ClaudeLauncherResolver(pathVariable: "")
            .resolve(kind: .custom, explicitPath: custom.path)
        #expect(launcher.kind == .custom)
        #expect(launcher.displayName == "my-claude")
        #expect(launcher.addsSkipPermissionsFlag)
    }

    @Test func nonExecutableExplicitPathIsRejected() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("not-exec", isDirectory: false)
        try "data".write(to: plain, atomically: true, encoding: .utf8)
        #expect(throws: ClaudeLauncherResolver.ResolutionError.notExecutable(
            path: plain.standardizedFileURL.path
        )) {
            _ = try ClaudeLauncherResolver(pathVariable: "")
                .resolve(kind: .claude, explicitPath: plain.path)
        }
    }
}

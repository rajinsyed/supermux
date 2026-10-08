import CmuxFoundation
import Foundation
import Testing

import SupermuxKit

/// A new worktree of a repository with submodules comes up with them checked
/// out (`git worktree add` leaves them empty). Ways this could fail:
///
/// 1. The submodule folders stay empty, so the worktree cannot build.
/// 2. Only top-level submodules are checked out, and a nested one stays empty.
/// 3. The submodules are checked out at a commit other than the one the
///    worktree's branch pins, so the fresh worktree already shows as changed
///    and cannot be removed without forcing.
/// 4. A submodule that cannot be fetched (offline, moved, auth) fails the
///    whole creation, losing a worktree that is otherwise usable.
@Suite(.serialized) struct SupermuxGitWorktreeSubmoduleTests {
    /// The service runs git through ``FileProtocolAllowingRunner``: the
    /// fixture submodules are local paths, which git refuses to clone for a
    /// submodule unless the file transport is allowed.
    private let service = SupermuxGitWorktreeService(runner: FileProtocolAllowingRunner())

    /// A repository with one submodule (`vendored`) that itself has a nested
    /// submodule (`vendored/nested`), plus the source repositories behind them.
    private struct Fixture {
        var root: String
        var library: String
        var inner: String
        var project: SupermuxProject

        func cleanUp() {
            GitFixture.cleanUp(root)
            GitFixture.cleanUp(library)
            GitFixture.cleanUp(inner)
        }
    }

    private func makeFixture() throws -> Fixture {
        let inner = try makeSourceRepo(file: "INNER.md")
        let library = try makeSourceRepo(file: "LIB.md")
        try addSubmodule(inner, at: "nested", in: library)
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-submodule-tests")
        try addSubmodule(library, at: "vendored", in: root)
        return Fixture(
            root: root,
            library: library,
            inner: inner,
            project: SupermuxProject(name: "Fixture", rootPath: root)
        )
    }

    private func makeSourceRepo(file: String) throws -> String {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-submodule-source")
        try GitFixture.write("\(file)\n", to: file, in: repo)
        try GitFixture.runGit(["add", file], in: repo)
        try GitFixture.commit("Add \(file)", in: repo)
        return repo
    }

    private func addSubmodule(_ source: String, at path: String, in repo: String) throws {
        try GitFixture.runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", "--quiet", source, path],
            in: repo
        )
        try GitFixture.commit("Add \(path)", in: repo)
    }

    private func fileExists(_ relativePath: String, in directory: String) -> Bool {
        FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(relativePath))
    }

    // MARK: - Tests

    @Test func createWorktreeChecksOutNestedSubmodules() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )

        #expect(fileExists("vendored/LIB.md", in: worktree.path))
        #expect(fileExists("vendored/nested/INNER.md", in: worktree.path))
        // Checked out at the pinned commits: nothing shows as changed.
        let status = try GitFixture.runGit(
            ["status", "--porcelain", "--ignore-submodules=none"],
            in: worktree.path
        )
        #expect(status.isEmpty)
    }

    @Test func unreachableSubmoduleDoesNotFailCreation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let moved = fixture.library + "-moved"
        try FileManager.default.moveItem(atPath: fixture.library, toPath: moved)
        defer { GitFixture.cleanUp(moved) }

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )

        #expect(fileExists("README.md", in: worktree.path))
        #expect(!fileExists("vendored/LIB.md", in: worktree.path))
    }
}

/// Delegates to the real `CommandRunner`, adding `-c protocol.file.allow=always`
/// to every git call (bare `git` or `/usr/bin/env … git`), so local-path
/// fixture submodules can be cloned. Production keeps git's default, which
/// blocks the file transport for submodules.
private actor FileProtocolAllowingRunner: CommandRunning {
    private let wrapped = CommandRunner()

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        var arguments = arguments
        let allowFile = ["-c", "protocol.file.allow=always"]
        if executable == "git" {
            arguments.insert(contentsOf: allowFile, at: 0)
        } else if executable == "/usr/bin/env", let git = arguments.firstIndex(of: "git") {
            arguments.insert(contentsOf: allowFile, at: git + 1)
        }
        return await wrapped.run(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }
}

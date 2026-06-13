import Foundation
import Testing

import SupermuxKit

/// Integration tests for `SupermuxGitWorktreeService` against real temporary
/// git repositories. Every test builds its own fixture repository so the
/// suite stays parallel-safe, and removes it on exit.
@Suite struct SupermuxGitWorktreeServiceTests {
    private let service = SupermuxGitWorktreeService()

    // MARK: - Fixture helpers

    /// A throwaway git repository plus the project record pointing at it.
    private struct Fixture {
        var root: String
        var project: SupermuxProject
    }

    /// A git invocation made by the fixture helper failed.
    private enum FixtureError: Error {
        case gitFailed(arguments: [String], message: String)
    }

    /// Creates a unique temporary directory and returns its path,
    /// standardized the same way the service normalizes paths.
    private func makeTempDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-worktree-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url.path as NSString).standardizingPath
    }

    /// Creates a temp git repository on `main` with one commit, plus a
    /// `SupermuxProject` pointing at it.
    private func makeFixtureRepo() throws -> Fixture {
        let root = try makeTempDirectory()
        try runGit(["init", "-b", "main"], in: root)
        try runGit(["config", "--local", "user.email", "tests@supermux.invalid"], in: root)
        try runGit(["config", "--local", "user.name", "Supermux Tests"], in: root)
        let readmePath = (root as NSString).appendingPathComponent("README.md")
        try "fixture\n".write(toFile: readmePath, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Initial commit"], in: root)
        return Fixture(root: root, project: SupermuxProject(name: "Fixture", rootPath: root))
    }

    /// Runs git synchronously via `Process` (test-only helper) and returns
    /// its standard output; throws on a non-zero exit.
    @discardableResult
    private func runGit(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.gitFailed(
                arguments: arguments,
                message: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    /// Best-effort removal of a fixture directory.
    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Repository probes

    @Test func isGitRepositoryDetectsReposAndPlainDirectories() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }
        let emptyDir = try makeTempDirectory()
        defer { cleanUp(emptyDir) }

        #expect(await service.isGitRepository(at: fixture.root))
        #expect(await service.isGitRepository(at: emptyDir) == false)
    }

    @Test func currentBranchReturnsMain() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }

        #expect(await service.currentBranch(repoRoot: fixture.root) == "main")
    }

    // MARK: - Worktree creation

    @Test func createWorktreeSanitizesBranchAndConfiguresCheckout() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "my feature"
        )

        #expect(worktree.branch == "my-feature")
        let expectedPath = (fixture.root as NSString)
            .appendingPathComponent(".worktrees/my-feature")
        #expect(worktree.path == expectedPath)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expectedPath, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)

        let listed = try await service.listWorktrees(for: fixture.project)
        let entry = try #require(listed.first { $0.path == expectedPath })
        #expect(entry.branch == "my-feature")
        #expect(entry.isSupermuxManaged)

        let excludePath = (fixture.root as NSString).appendingPathComponent(".git/info/exclude")
        let exclude = try String(contentsOfFile: excludePath, encoding: .utf8)
        #expect(exclude.contains("/.worktrees/"))

        let autoSetupRemote = try runGit(
            ["-C", worktree.path, "config", "--local", "push.autoSetupRemote"],
            in: fixture.root
        )
        #expect(autoSetupRemote.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }

    @Test func createWorktreeDeduplicatesBranchNames() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }

        let first = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "my feature"
        )
        let second = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "my feature"
        )

        #expect(first.branch == "my-feature")
        #expect(second.branch == "my-feature-2")
    }

    @Test func createWorktreeRecordsBaseBranch() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature",
            baseBranch: "main"
        )

        let branch = try #require(worktree.branch)
        let recordedBase = try runGit(["config", "branch.\(branch).base"], in: fixture.root)
        #expect(recordedBase.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }

    // MARK: - Worktree removal

    @Test func removeWorktreeRemovesCleanCheckout() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )

        try await service.removeWorktree(worktree, project: fixture.project)

        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    }

    @Test func removeWorktreeRefusesDirtyCheckoutUnlessForced() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )
        let untrackedPath = (worktree.path as NSString).appendingPathComponent("scratch.txt")
        try "uncommitted\n".write(toFile: untrackedPath, atomically: true, encoding: .utf8)

        await #expect(throws: SupermuxGitError.dirtyWorktree(path: worktree.path)) {
            try await service.removeWorktree(worktree, project: fixture.project)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try await service.removeWorktree(worktree, project: fixture.project, force: true)
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    }

    @Test func removeWorktreeCanDeleteBranch() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )
        let branch = try #require(worktree.branch)

        try await service.removeWorktree(worktree, project: fixture.project, deleteBranch: true)

        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
        let listing = try runGit(["branch", "--list", branch], in: fixture.root)
        #expect(listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func removeWorktreeRefusesUnmanagedWorktrees() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }
        let sibling = try makeTempDirectory()
        defer { cleanUp(sibling) }
        let outsidePath = (sibling as NSString).appendingPathComponent("manual-worktree")
        try runGit(["worktree", "add", "-b", "manual-branch", outsidePath], in: fixture.root)

        let listed = try await service.listWorktrees(for: fixture.project)
        let manual = try #require(listed.first { $0.branch == "manual-branch" })
        #expect(manual.isSupermuxManaged == false)

        await #expect(throws: SupermuxGitError.unmanagedWorktree(path: manual.path)) {
            try await service.removeWorktree(manual, project: fixture.project)
        }
    }
}

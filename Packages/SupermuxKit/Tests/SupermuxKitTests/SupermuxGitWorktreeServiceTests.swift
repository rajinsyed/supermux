import Foundation
import Testing

import SupermuxKit

/// Integration tests for `SupermuxGitWorktreeService` against real temporary
/// git repositories. Every test builds its own fixture repository so the
/// suite stays parallel-safe, and removes it on exit.
// Serialized: these tests shell out to real `git`. Run alongside the other
// git-integration suites they spawned enough concurrent subprocesses to flake
// (a fixture's `git init` intermittently read back as "not a git repository").
// Serializing keeps peak git-subprocess concurrency low without slowing CI
// meaningfully.
@Suite(.serialized) struct SupermuxGitWorktreeServiceTests {
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

    @Test func createWorktreeGeneratesFriendlyNameWhenBranchBlank() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }

        // A blank branch field must not error — it generates a friendly,
        // git-safe two-word branch and a real worktree on disk.
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "   "
        )

        let branch = try #require(worktree.branch)
        let parts = branch.split(separator: "-", omittingEmptySubsequences: false)
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { !$0.isEmpty })
        #expect(SupermuxBranchName().sanitize(branch) == branch)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
        #expect(worktree.isSupermuxManaged)
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

    // MARK: - Path-escape regressions

    /// A project whose `worktreesDirName` is `".."` resolves its worktrees
    /// container to the *parent* of the repository. `createWorktree` must refuse
    /// with ``SupermuxGitError/unsafeWorktreePath(path:)`` and must not create any
    /// directory in that parent.
    @Test func createWorktreeRejectsEscapingWorktreesDir() async throws {
        // Nest the repo inside a controlled parent we own so we can assert on the
        // parent's contents without racing the shared system temp directory.
        let parent = try makeTempDirectory()
        defer { cleanUp(parent) }
        let root = (parent as NSString).appendingPathComponent("repo")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: root)
        try runGit(["config", "--local", "user.email", "tests@supermux.invalid"], in: root)
        try runGit(["config", "--local", "user.name", "Supermux Tests"], in: root)
        let readmePath = (root as NSString).appendingPathComponent("README.md")
        try "fixture\n".write(toFile: readmePath, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Initial commit"], in: root)

        let escaped = SupermuxProject(
            name: "Escaped",
            rootPath: root,
            worktreesDirName: ".."
        )

        await #expect(throws: SupermuxGitError.self) {
            try await service.createWorktree(project: escaped, requestedBranch: "escape")
        }

        // And specifically the unsafe-path case (not, say, a generic git failure).
        do {
            _ = try await service.createWorktree(project: escaped, requestedBranch: "escape")
            Issue.record("Expected createWorktree to throw for an escaping worktrees dir")
        } catch let error as SupermuxGitError {
            guard case .unsafeWorktreePath = error else {
                Issue.record("Expected .unsafeWorktreePath, got \(error)")
                return
            }
        }

        // Nothing escaped into the parent: only the repo itself remains, and no
        // "escape" worktree directory was created next to it.
        let parentEntries = Set((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
        #expect(parentEntries == ["repo"])
        #expect(parentEntries.contains("escape") == false)
        #expect(FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent("escape")) == false)
    }

    /// A worktree living *outside* the project root must never be flagged as
    /// supermux-managed for a project whose `worktreesDirName` escaped the root.
    /// With the corrupt `".."` config the managed prefix resolves to the parent
    /// directory, so a worktree placed directly under that parent (a sibling of
    /// the repo) would be mis-flagged managed and offered up for deletion. The
    /// service must fall back to a match-nothing sentinel instead.
    @Test func listWorktreesNeverFlagsSiblingsManagedForEscapingConfig() async throws {
        let fixture = try makeFixtureRepo()
        defer { cleanUp(fixture.root) }

        // A second, independent git repo living as a sibling of the fixture,
        // with its own real worktree (also a sibling of the fixture). It must
        // never be reported as supermux-managed.
        let parent = (fixture.root as NSString).deletingLastPathComponent
        let siblingRoot = (parent as NSString)
            .appendingPathComponent("supermux-sibling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: siblingRoot, withIntermediateDirectories: true)
        defer { cleanUp(siblingRoot) }
        try runGit(["init", "-b", "main"], in: siblingRoot)
        try runGit(["config", "--local", "user.email", "tests@supermux.invalid"], in: siblingRoot)
        try runGit(["config", "--local", "user.name", "Supermux Tests"], in: siblingRoot)
        let siblingReadme = (siblingRoot as NSString).appendingPathComponent("README.md")
        try "sibling\n".write(toFile: siblingReadme, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: siblingRoot)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Sibling commit"], in: siblingRoot)
        let siblingWorktree = (parent as NSString)
            .appendingPathComponent("supermux-sibling-wt-\(UUID().uuidString)")
        defer { cleanUp(siblingWorktree) }
        try runGit(["worktree", "add", "-b", "sibling-branch", siblingWorktree], in: siblingRoot)

        // `git worktree list` in the fixture repo only enumerates the fixture's
        // own worktrees, so to exercise the managed-flagging path we give the
        // fixture a worktree that lives directly under the parent — i.e. inside
        // the directory the escaped `".."` config resolves the managed prefix
        // to. Under the bug this fixture-owned sibling would be flagged managed.
        let escapingWorktree = (parent as NSString)
            .appendingPathComponent("supermux-escaped-wt-\(UUID().uuidString)")
        defer { cleanUp(escapingWorktree) }
        try runGit(["worktree", "add", "-b", "escaped-branch", escapingWorktree], in: fixture.root)

        // The fixture project, but mis-configured to escape into the parent.
        let escaped = SupermuxProject(
            name: "Escaped",
            rootPath: fixture.root,
            worktreesDirName: ".."
        )

        // With the escaped config NO listed worktree may be flagged managed: a
        // corrupt prefix must fall back to a sentinel that matches nothing so no
        // sibling worktree is ever reported deletable.
        let listed = try await service.listWorktrees(for: escaped)
        #expect(listed.isEmpty == false)
        for worktree in listed {
            #expect(worktree.isSupermuxManaged == false)
        }
        // The fixture-owned worktree under the parent specifically must be unmanaged.
        let normalizedEscaping = (escapingWorktree as NSString).standardizingPath
        let escapedEntry = try #require(listed.first { $0.path == normalizedEscaping })
        #expect(escapedEntry.isSupermuxManaged == false)
        // And if the sibling repo's worktree ever surfaced here, it must not be managed.
        let normalizedSibling = (siblingWorktree as NSString).standardizingPath
        if let sibling = listed.first(where: { $0.path == normalizedSibling }) {
            #expect(sibling.isSupermuxManaged == false)
        }
    }

    /// Documents *why* the service guard is needed: `worktreesDirName == ".."`
    /// makes the worktrees container resolve to the project's parent directory.
    /// No git involved — a plain value assertion about path resolution.
    @Test func worktreesDirPathWithDotDotResolvesToParent() {
        let root = "/Users/example/projects/repo"
        let project = SupermuxProject(name: "Repo", rootPath: root, worktreesDirName: "..")

        // The raw path appends ".." literally; standardizing collapses it to the parent.
        let resolved = (project.worktreesDirPath as NSString).standardizingPath
        let parent = (root as NSString).deletingLastPathComponent
        #expect(resolved == parent)
        // The resolved container is NOT inside the root — exactly the unsafe case
        // the service rejects with `.unsafeWorktreePath`.
        #expect(resolved.hasPrefix(root + "/") == false)
    }
}

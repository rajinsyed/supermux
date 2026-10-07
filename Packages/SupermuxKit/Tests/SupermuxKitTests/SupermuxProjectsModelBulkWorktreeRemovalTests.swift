import Foundation
import Testing
@testable import SupermuxKit

/// Behavior tests for the project-level "Delete All Worktrees" path
/// (``SupermuxProjectsModel/removeAllWorktrees(projectId:deleteBranch:)``):
/// every clean worktree goes wherever it lives, dirty ones are kept and
/// reported for a forced retry, and the main checkout is never touched.
// Serialized: shells out to real `git` (see SupermuxGitWorktreeServiceTests
// for the concurrency rationale).
@Suite(.serialized)
@MainActor
struct SupermuxProjectsModelBulkWorktreeRemovalTests {
    /// Builds a model whose projects file lives inside `root` (the fixture
    /// repo), so the fixture's `cleanUp` removes it too — no stray temp dirs.
    private func makeLoadedModel(project: SupermuxProject, in root: String) async throws -> SupermuxProjectsModel {
        let directory = URL(fileURLWithPath: root).appendingPathComponent(".supermux-test-state", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SupermuxProjectStore(fileURL: directory.appendingPathComponent("projects.json"))
        try await store.save(SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: [project],
            isSectionCollapsed: false
        ))
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())
        await model.loadIfNeeded()
        return model
    }

    private func branchExists(_ branch: String, in root: String) throws -> Bool {
        let listing = try GitFixture.runGit(["branch", "--list", branch], in: root)
        return !listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @Test func removeAllRemovesEveryCleanManagedWorktree() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(root) }
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let model = try await makeLoadedModel(project: project, in: root)
        let first = try await model.createWorktree(projectId: project.id, branchName: "feature one", baseBranch: nil)
        let second = try await model.createWorktree(projectId: project.id, branchName: "feature two", baseBranch: nil)

        let result = try await model.removeAllWorktrees(projectId: project.id, deleteBranch: false)

        #expect(Set(result.removed.map(\.path)) == [first.path, second.path])
        #expect(result.dirty.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(model.worktreesByProjectId[project.id]?.isEmpty == true)
        // Branches survive unless asked for.
        #expect(try branchExists("feature-one", in: root))
        #expect(try branchExists("feature-two", in: root))
    }

    @Test func removeAllCanDeleteBranchesToo() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(root) }
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let model = try await makeLoadedModel(project: project, in: root)
        _ = try await model.createWorktree(projectId: project.id, branchName: "feature one", baseBranch: nil)
        _ = try await model.createWorktree(projectId: project.id, branchName: "feature two", baseBranch: nil)

        let result = try await model.removeAllWorktrees(projectId: project.id, deleteBranch: true)

        #expect(result.removed.count == 2)
        #expect(try !branchExists("feature-one", in: root))
        #expect(try !branchExists("feature-two", in: root))
    }

    @Test func removeAllKeepsDirtyWorktreesUntilForced() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(root) }
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let model = try await makeLoadedModel(project: project, in: root)
        let clean = try await model.createWorktree(projectId: project.id, branchName: "clean", baseBranch: nil)
        let dirty = try await model.createWorktree(projectId: project.id, branchName: "dirty", baseBranch: nil)
        try GitFixture.write("wip\n", to: "untracked.txt", in: dirty.path)

        let first = try await model.removeAllWorktrees(projectId: project.id, deleteBranch: false)

        #expect(first.removed.map(\.path) == [clean.path])
        #expect(first.dirty.map(\.path) == [dirty.path])
        #expect(first.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: clean.path))
        #expect(FileManager.default.fileExists(atPath: dirty.path))
        #expect(model.worktreesByProjectId[project.id]?.map(\.path) == [dirty.path])

        // The forced retry the UI offers after the user acknowledges the loss.
        let forced = await model.removeWorktrees(first.dirty, projectId: project.id, force: true, deleteBranch: false)

        #expect(forced.removed.map(\.path) == [dirty.path])
        #expect(forced.dirty.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dirty.path))
        #expect(model.worktreesByProjectId[project.id]?.isEmpty == true)
    }

    /// Worktrees made by another tool (outside `<root>/.worktrees`) are the
    /// project's worktrees too: Delete All removes them like supermux's own.
    @Test func removeAllAlsoRemovesWorktreesOutsideTheWorktreesFolder() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(root) }
        let sibling = try GitFixture.makeTempDirectory(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(sibling) }
        let manualPath = (sibling as NSString).appendingPathComponent("manual-worktree")
        try GitFixture.runGit(["worktree", "add", "-b", "manual-branch", manualPath], in: root)
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let model = try await makeLoadedModel(project: project, in: root)
        let managed = try await model.createWorktree(projectId: project.id, branchName: "managed", baseBranch: nil)

        let result = try await model.removeAllWorktrees(projectId: project.id, deleteBranch: false)

        #expect(Set(result.removed.map(\.branch)) == ["manual-branch", "managed"])
        #expect(result.dirty.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manualPath))
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(FileManager.default.fileExists(atPath: root))
        #expect(model.worktreesByProjectId[project.id]?.isEmpty == true)
    }

    /// A project registered at a linked worktree sees the repository's main
    /// checkout in `git worktree list`. It is never offered for deletion: no
    /// teardown script may run there and git would refuse to remove it anyway.
    @Test func removeAllNeverTouchesTheMainCheckout() async throws {
        let main = try GitFixture.makeFixtureRepo(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(main) }
        let sibling = try GitFixture.makeTempDirectory(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(sibling) }
        let linkedRoot = (sibling as NSString).appendingPathComponent("linked-root")
        let other = (sibling as NSString).appendingPathComponent("other")
        try GitFixture.runGit(["worktree", "add", "-b", "linked-root", linkedRoot], in: main)
        try GitFixture.runGit(["worktree", "add", "-b", "other", other], in: main)
        try GitFixture.write("wip\n", to: "untracked.txt", in: main)
        let project = SupermuxProject(name: "Linked", rootPath: linkedRoot)
        let model = try await makeLoadedModel(project: project, in: linkedRoot)

        let result = try await model.removeAllWorktrees(projectId: project.id, deleteBranch: false)

        #expect(result.removed.map(\.branch) == ["other"])
        #expect(result.dirty.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: (main as NSString).appendingPathComponent("untracked.txt")))
        #expect(FileManager.default.fileExists(atPath: linkedRoot))
    }

    /// A failed `git worktree list` must surface as an error, not as a silent
    /// no-op: `refreshWorktrees(for:)` clears the cached list to `[]` on failure,
    /// which would otherwise make Delete All "succeed" while removing nothing.
    @Test func removeAllThrowsWhenWorktreesCannotBeListed() async throws {
        let notARepo = try GitFixture.makeTempDirectory(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(notARepo) }
        let project = SupermuxProject(name: "Plain folder", rootPath: notARepo)
        let model = try await makeLoadedModel(project: project, in: notARepo)

        await #expect(throws: SupermuxGitError.self) {
            try await model.removeAllWorktrees(projectId: project.id, deleteBranch: false)
        }
    }

    @Test func removeWorktreesReportsTerminalFailuresWithoutStopping() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-bulk-worktree-removal")
        defer { GitFixture.cleanUp(root) }
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let model = try await makeLoadedModel(project: project, in: root)
        let real = try await model.createWorktree(projectId: project.id, branchName: "real", baseBranch: nil)
        // A worktree that no longer exists on disk fails inside git; the pass
        // must record it and still remove the worktree after it.
        let unmanaged = SupermuxProjectWorktree(path: "/nonexistent/manual", branch: "manual", isSupermuxManaged: false)

        let result = await model.removeWorktrees([unmanaged, real], projectId: project.id, force: false, deleteBranch: false)

        #expect(result.failures.map(\.worktree.path) == [unmanaged.path])
        #expect(result.failures.first?.error is SupermuxGitError)
        #expect(result.removed.map(\.path) == [real.path])
        #expect(!FileManager.default.fileExists(atPath: real.path))
    }
}

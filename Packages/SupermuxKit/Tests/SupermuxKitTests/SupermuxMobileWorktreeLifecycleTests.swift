import Foundation
import Testing
@testable import SupermuxKit

/// Lifecycle tests for the mobile worktree create/remove flow (validation
/// contract RPC-WT-02), driven through the exact ``SupermuxProjectsModel``
/// calls the `mobile.supermux.worktree.*` handlers make: create returns the
/// worktree and it exists on disk; removing a dirtied worktree without `force`
/// surfaces the `dirty_worktree` wire code; the forced retry succeeds and runs
/// the project's teardown script headlessly.
// Serialized: shells out to real `git` (see SupermuxGitWorktreeServiceTests
// for the concurrency rationale).
@Suite(.serialized)
@MainActor
struct SupermuxMobileWorktreeLifecycleTests {
    /// Builds a model whose temp projects file on disk carries `project`,
    /// mirroring how the app composition loads the shared model.
    private func makeLoadedModel(project: SupermuxProject) async throws -> SupermuxProjectsModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-mobile-worktree-lifecycle-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - RPC-WT-02

    @Test func createDirtyRemoveForceLifecycleMatchesTheWireContract() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-mobile-worktree-lifecycle")
        defer { GitFixture.cleanUp(root) }
        var project = SupermuxProject(name: "Fixture", rootPath: root)
        // Teardown drops a marker into the MAIN checkout so the test can prove
        // the script ran headlessly during removal (the worktree itself is gone).
        project.teardownCommands = [
            #"printf 'ran' > "$SUPERSET_ROOT_PATH/mobile-teardown-marker""#,
        ]
        let model = try await makeLoadedModel(project: project)

        // Create — the same model call `mobile.supermux.worktree.create` makes.
        let worktree = try await model.createWorktree(
            projectId: project.id,
            branchName: "mobile feature",
            baseBranch: nil
        )
        #expect(worktree.branch == "mobile-feature")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect((model.worktreesByProjectId[project.id] ?? []).contains { $0.path == worktree.path })

        // Dirty the worktree with an untracked file.
        try GitFixture.write("wip\n", to: "untracked.txt", in: worktree.path)

        // Remove without force → the dirty guard rejects with `dirty_worktree`.
        var thrown: SupermuxGitError?
        do {
            try await model.removeWorktree(worktree, projectId: project.id, force: false, deleteBranch: false)
        } catch let error as SupermuxGitError {
            thrown = error
        }
        #expect(thrown == .dirtyWorktree(path: worktree.path))
        #expect(SupermuxMobileWorktreeErrorCode.wireCode(for: try #require(thrown)) == "dirty_worktree")
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        // Forced retry → removal succeeds and the teardown script ran headless.
        try await model.removeWorktree(worktree, projectId: project.id, force: true, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        let markerPath = (root as NSString).appendingPathComponent("mobile-teardown-marker")
        #expect(FileManager.default.fileExists(atPath: markerPath))
        #expect(try GitFixture.read("mobile-teardown-marker", in: root) == "ran")
        #expect(model.worktreesByProjectId[project.id]?.isEmpty == true)
    }

    // MARK: - Wire error mapping

    @Test func wireCodesMapEveryGitErrorOntoReservedCodes() {
        #expect(SupermuxMobileWorktreeErrorCode.wireCode(for: .dirtyWorktree(path: "/x")) == "dirty_worktree")
        #expect(SupermuxMobileWorktreeErrorCode.wireCode(for: .unmanagedWorktree(path: "/x")) == "forbidden")
        #expect(SupermuxMobileWorktreeErrorCode.wireCode(for: .notAGitRepository(path: "/x")) == "invalid_params")
        #expect(SupermuxMobileWorktreeErrorCode.wireCode(for: .invalidBranchName(input: "?")) == "invalid_params")
        #expect(SupermuxMobileWorktreeErrorCode.wireCode(for: .unknownBaseBranch(name: "nope")) == "invalid_params")
        #expect(SupermuxMobileWorktreeErrorCode.wireCode(for: .unsafeWorktreePath(path: "/x")) == "unavailable")
        #expect(SupermuxMobileWorktreeErrorCode.wireCode(for: .gitFailed(command: "x", message: "y")) == "unavailable")
    }
}

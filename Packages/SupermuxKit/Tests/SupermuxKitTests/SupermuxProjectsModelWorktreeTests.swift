import Foundation
import Testing
@testable import SupermuxKit

/// Worktree-lifecycle behavior of `SupermuxProjectsModel` that the sidebar
/// relies on, driven against a real fixture repository.
// Serialized: shells out to real `git` (see SupermuxGitWorktreeServiceTests
// for the concurrency rationale).
@Suite(.serialized)
@MainActor
struct SupermuxProjectsModelWorktreeTests {
    private func makeLoadedModel(project: SupermuxProject) async throws -> SupermuxProjectsModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-model-worktree-\(UUID().uuidString)", isDirectory: true)
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

    /// Creating a worktree must not pop open the project's worktree
    /// disclosure: the user's collapsed/expanded choice is theirs to change.
    @Test func createWorktreeLeavesCollapsedProjectCollapsed() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-model-worktree")
        defer { GitFixture.cleanUp(root) }
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let model = try await makeLoadedModel(project: project)
        #expect(model.expandedProjectIds.contains(project.id) == false)

        let worktree = try await model.createWorktree(projectId: project.id, branchName: "feature", baseBranch: nil)

        #expect(model.expandedProjectIds.contains(project.id) == false)
        #expect((model.worktreesByProjectId[project.id] ?? []).contains { $0.path == worktree.path })
    }

    /// And the converse: an already-expanded project stays expanded.
    @Test func createWorktreeLeavesExpandedProjectExpanded() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-model-worktree")
        defer { GitFixture.cleanUp(root) }
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let model = try await makeLoadedModel(project: project)
        model.expandedProjectIds.insert(project.id)

        _ = try await model.createWorktree(projectId: project.id, branchName: "feature", baseBranch: nil)

        #expect(model.expandedProjectIds.contains(project.id))
    }
}

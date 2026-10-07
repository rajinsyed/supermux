import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// Wire-payload tests for the `mobile.supermux.worktrees.list` read path
/// (validation contract RPC-WT-01): worktrees discovered from a fixture git
/// repository fold open-workspace state into `is_open`/`workspace_id`,
/// decoding back through the shared ``SupermuxWireJSON`` bridge.
// Serialized: shells out to real `git` (see SupermuxGitWorktreeServiceTests
// for the concurrency rationale).
@Suite(.serialized)
@MainActor
struct SupermuxMobileWorktreesPayloadTests {
    // MARK: - RPC-WT-01

    @Test func listEncodesDiscoveredUnopenedWorktree() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-mobile-worktrees")
        defer { GitFixture.cleanUp(root) }
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let service = SupermuxGitWorktreeService()
        let created = try await service.createWorktree(project: project, requestedBranch: "fix login")
        let worktrees = try await service.listWorktrees(for: project)
        #expect(worktrees.count == 1)

        let payload = try SupermuxMobileWorktreesPayloadBuilder().worktreesList(
            worktrees: worktrees,
            branches: ["main", "experiment"],
            openWorkspaces: []
        )

        #expect(payload["branches"] as? [String] == ["main", "experiment"])
        let entries = try #require(payload["worktrees"] as? [[String: Any]])
        #expect(entries.count == 1)
        let dto = try SupermuxWireJSON().decode(SupermuxWorktreeDTO.self, from: try #require(entries.first))
        #expect(dto.path == created.path)
        #expect(dto.branch == "fix-login")
        #expect(dto.isOpen == false)
        #expect(dto.workspaceId == nil)
    }

    @Test func listMarksOpenWorktrees() throws {
        let worktree = SupermuxProjectWorktree(
            path: "/tmp/supermux-fixture/.worktrees/feature",
            branch: "feature",
            isSupermuxManaged: true
        )
        let workspaceID = UUID()

        let payload = try SupermuxMobileWorktreesPayloadBuilder().worktreesList(
            worktrees: [worktree],
            openWorkspaces: [
                SupermuxOpenWorkspace(
                    id: workspaceID,
                    title: "feature",
                    directory: worktree.path,
                    isSelected: false
                ),
            ]
        )

        let entries = try #require(payload["worktrees"] as? [[String: Any]])
        let dto = try SupermuxWireJSON().decode(SupermuxWorktreeDTO.self, from: try #require(entries.first))
        #expect(dto.isOpen == true)
        #expect(dto.workspaceId == workspaceID.uuidString)
    }

    @Test func worktreeWithoutWorkspaceCarriesNoWorkspaceOrPullRequestField() throws {
        let worktree = SupermuxProjectWorktree(
            path: "/tmp/supermux-fixture/.worktrees/plain",
            branch: "plain",
            isSupermuxManaged: true
        )
        let payload = try SupermuxMobileWorktreesPayloadBuilder().worktreesList(
            worktrees: [worktree],
            openWorkspaces: []
        )
        let entries = try #require(payload["worktrees"] as? [[String: Any]])
        let entry = try #require(entries.first)
        #expect(entry["pull_request"] == nil)
        #expect(entry["workspace_id"] == nil)
        #expect(entry["is_open"] as? Bool == false)
        #expect(entry["branch"] as? String == "plain")
        #expect(payload["branches"] == nil)
    }
}

import CmuxGit
import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// Wire-payload tests for the `mobile.supermux.worktrees.list` read path
/// (validation contract RPC-WT-01): worktrees discovered from a fixture git
/// repository fold pull-request data — stubbed through a real
/// ``SupermuxWorktreePullRequestModel`` — into
/// `SupermuxWorktreeDTO.pull_request`, and open-workspace state into
/// `is_open`/`workspace_id`, decoding back through the shared
/// ``SupermuxWireJSON`` bridge.
// Serialized: shells out to real `git` (see SupermuxGitWorktreeServiceTests
// for the concurrency rationale).
@Suite(.serialized)
@MainActor
struct SupermuxMobileWorktreesPayloadTests {
    /// Scripted ``SupermuxPullRequestResolving`` so the PR model resolves a
    /// canned pull request per path without the network pipeline.
    private struct StubResolver: SupermuxPullRequestResolving {
        let pullRequestsByPath: [String: SupermuxPullRequest]

        func resolve(
            targets: [SupermuxPullRequestTarget],
            cache: [String: WorkspacePullRequestRepoCacheEntry],
            allowCache: Bool,
            now: Date
        ) async -> SupermuxPullRequestProbe.Outcome {
            let resolutions = targets.map { target -> SupermuxPullRequestProbe.PathResolution in
                if let pullRequest = pullRequestsByPath[target.path] {
                    return .init(path: target.path, resolution: .pullRequest(pullRequest))
                }
                return .init(path: target.path, resolution: .absent)
            }
            return .init(resolutions: resolutions, updatedCache: cache)
        }
    }

    // MARK: - RPC-WT-01

    @Test func listFoldsStubbedOpenPullRequestIntoUnopenedWorktree() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-mobile-worktrees")
        defer { GitFixture.cleanUp(root) }
        let project = SupermuxProject(name: "Fixture", rootPath: root)
        let service = SupermuxGitWorktreeService()
        let created = try await service.createWorktree(project: project, requestedBranch: "fix login")
        let worktrees = try await service.listWorktrees(for: project)
        #expect(worktrees.count == 1)

        // Stub the PR model with one open PR for the worktree's path.
        let pullRequest = SupermuxPullRequest(
            number: 41,
            status: .open,
            url: try #require(URL(string: "https://github.com/acme/app/pull/41")),
            title: "Fix login flow"
        )
        let model = SupermuxWorktreePullRequestModel(
            probe: StubResolver(pullRequestsByPath: [created.path: pullRequest])
        )
        await model.refresh(
            targets: [SupermuxPullRequestTarget(path: created.path, branch: created.branch ?? "")],
            allowCache: false
        )

        let payload = try SupermuxMobileWorktreesPayloadBuilder().worktreesList(
            worktrees: worktrees,
            openWorkspaces: [],
            pullRequestsByWorktreePath: model.pullRequestsByWorktreePath
        )

        let entries = try #require(payload["worktrees"] as? [[String: Any]])
        #expect(entries.count == 1)
        let dto = try SupermuxWireJSON().decode(SupermuxWorktreeDTO.self, from: try #require(entries.first))
        #expect(dto.path == created.path)
        #expect(dto.branch == "fix-login")
        #expect(dto.isOpen == false)
        #expect(dto.workspaceId == nil)
        let wirePullRequest = try #require(dto.pullRequest)
        #expect(wirePullRequest.number == 41)
        #expect(wirePullRequest.state == "open")
        #expect(wirePullRequest.title == "Fix login flow")
        #expect(wirePullRequest.url == "https://github.com/acme/app/pull/41")
    }

    @Test func listMarksOpenWorktreesAndPrefersTheOpenWorkspacesPullRequest() throws {
        let worktree = SupermuxProjectWorktree(
            path: "/tmp/supermux-fixture/.worktrees/feature",
            branch: "feature",
            isSupermuxManaged: true
        )
        let workspacePullRequest = SupermuxPullRequest(
            number: 7,
            status: .open,
            url: try #require(URL(string: "https://github.com/acme/app/pull/7")),
            title: "From workspace"
        )
        let modelPullRequest = SupermuxPullRequest(
            number: 8,
            status: .closed,
            url: try #require(URL(string: "https://github.com/acme/app/pull/8")),
            title: "From model"
        )
        let workspaceID = UUID()

        let payload = try SupermuxMobileWorktreesPayloadBuilder().worktreesList(
            worktrees: [worktree],
            openWorkspaces: [
                SupermuxOpenWorkspace(
                    id: workspaceID,
                    title: "feature",
                    directory: worktree.path,
                    isSelected: false,
                    pullRequest: workspacePullRequest
                ),
            ],
            pullRequestsByWorktreePath: [worktree.path: modelPullRequest]
        )

        let entries = try #require(payload["worktrees"] as? [[String: Any]])
        let dto = try SupermuxWireJSON().decode(SupermuxWorktreeDTO.self, from: try #require(entries.first))
        #expect(dto.isOpen == true)
        #expect(dto.workspaceId == workspaceID.uuidString)
        // The open workspace's PR (cmux's own per-workspace probe) wins over
        // the unopened-worktree model, mirroring the desktop sidebar.
        #expect(dto.pullRequest?.number == 7)
        #expect(dto.pullRequest?.state == "open")
        #expect(dto.pullRequest?.title == "From workspace")
    }

    @Test func worktreeWithoutPullRequestOrWorkspaceCarriesNeitherField() throws {
        let worktree = SupermuxProjectWorktree(
            path: "/tmp/supermux-fixture/.worktrees/plain",
            branch: "plain",
            isSupermuxManaged: true
        )
        let payload = try SupermuxMobileWorktreesPayloadBuilder().worktreesList(
            worktrees: [worktree],
            openWorkspaces: [],
            pullRequestsByWorktreePath: [:]
        )
        let entries = try #require(payload["worktrees"] as? [[String: Any]])
        let entry = try #require(entries.first)
        #expect(entry["pull_request"] == nil)
        #expect(entry["workspace_id"] == nil)
        #expect(entry["is_open"] as? Bool == false)
        #expect(entry["branch"] as? String == "plain")
    }
}

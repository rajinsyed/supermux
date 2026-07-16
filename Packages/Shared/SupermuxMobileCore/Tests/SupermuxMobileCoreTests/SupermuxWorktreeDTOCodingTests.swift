import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxWorktreeDTOCodingTests {
    private let coding = WireCodingTestSupport()

    private var fullWorktree: SupermuxWorktreeDTO {
        SupermuxWorktreeDTO(
            path: "/Users/dev/supermux/.worktrees/fix-bug",
            branch: "fix-bug",
            baseBranch: "main",
            isOpen: true,
            workspaceId: "workspace:7",
            isDirty: false,
            pullRequest: SupermuxPullRequestDTO(
                number: 42,
                state: "open",
                title: "Fix the bug",
                url: "https://github.com/example/repo/pull/42"
            )
        )
    }

    @Test func worktreeRoundTrips() throws {
        #expect(try coding.roundTrip(fullWorktree) == fullWorktree)
    }

    @Test func worktreeEncodesSnakeCaseKeys() throws {
        let keys = try coding.encodedKeys(of: fullWorktree)
        #expect(keys == [
            "path", "branch", "base_branch", "is_open",
            "workspace_id", "is_dirty", "pull_request",
        ])
    }

    @Test func worktreeDecodesWithOnlyEssentialFields() throws {
        let worktree = try coding.decode(SupermuxWorktreeDTO.self, from: #"{"path": "/tmp/wt"}"#)
        #expect(worktree.path == "/tmp/wt")
        #expect(worktree.branch == nil)
        #expect(worktree.isOpen == nil)
        #expect(worktree.pullRequest == nil)
    }

    @Test func worktreeUnknownFieldTolerance() throws {
        let json = """
        {
          "path": "/tmp/wt",
          "branch": "main",
          "is_open": false,
          "future_field": "ignored",
          "pull_request": {"number": 7, "state": "merged", "confetti": true}
        }
        """
        let worktree = try coding.decode(SupermuxWorktreeDTO.self, from: json)
        #expect(worktree.branch == "main")
        #expect(worktree.pullRequest?.number == 7)
        #expect(worktree.pullRequest?.state == "merged")
    }

    @Test func pullRequestRoundTrips() throws {
        let pullRequest = SupermuxPullRequestDTO(
            number: 9,
            state: "closed",
            title: "Old change",
            url: "https://example.com/pull/9"
        )
        #expect(try coding.roundTrip(pullRequest) == pullRequest)
        let keys = try coding.encodedKeys(of: pullRequest)
        #expect(keys == ["number", "state", "title", "url"])
    }

    @Test func pullRequestUnknownFieldTolerance() throws {
        let json = #"{"number": 3, "review_bots": ["a", "b"]}"#
        let pullRequest = try coding.decode(SupermuxPullRequestDTO.self, from: json)
        #expect(pullRequest.number == 3)
        #expect(pullRequest.state == nil)
    }
}

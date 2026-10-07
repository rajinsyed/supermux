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
            isDirty: false
        )
    }

    @Test func worktreeRoundTrips() throws {
        #expect(try coding.roundTrip(fullWorktree) == fullWorktree)
    }

    @Test func worktreeEncodesSnakeCaseKeys() throws {
        let keys = try coding.encodedKeys(of: fullWorktree)
        #expect(keys == [
            "path", "branch", "base_branch", "is_open",
            "workspace_id", "is_dirty",
        ])
    }

    @Test func worktreeDecodesWithOnlyEssentialFields() throws {
        let worktree = try coding.decode(SupermuxWorktreeDTO.self, from: #"{"path": "/tmp/wt"}"#)
        #expect(worktree.path == "/tmp/wt")
        #expect(worktree.branch == nil)
        #expect(worktree.isOpen == nil)
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
        // An older Mac still sends `pull_request`; it decodes and is ignored.
        let worktree = try coding.decode(SupermuxWorktreeDTO.self, from: json)
        #expect(worktree.branch == "main")
        #expect(worktree.isOpen == false)
    }
}

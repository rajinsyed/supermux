import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxChangesDTOCodingTests {
    private let coding = WireCodingTestSupport()

    private var fullStatus: SupermuxChangesStatusDTO {
        SupermuxChangesStatusDTO(
            workspaceId: "workspace:1",
            isRepository: true,
            branch: "main",
            upstreamBranch: "origin/main",
            ahead: 2,
            behind: 1,
            staged: [SupermuxChangedFileDTO(path: "a.swift", oldPath: nil, kind: "modified")],
            unstaged: [SupermuxChangedFileDTO(path: "b.swift", oldPath: "old-b.swift", kind: "renamed")],
            untracked: [SupermuxChangedFileDTO(path: "new.txt", oldPath: nil, kind: "untracked")],
            stashCount: 3
        )
    }

    @Test func statusRoundTrips() throws {
        #expect(try coding.roundTrip(fullStatus) == fullStatus)
    }

    @Test func statusEncodesSnakeCaseKeys() throws {
        let keys = try coding.encodedKeys(of: fullStatus)
        #expect(keys == [
            "workspace_id", "is_repository", "branch", "upstream_branch",
            "ahead", "behind", "staged", "unstaged", "untracked", "stash_count",
        ])
    }

    @Test func statusDecodesFromEmptyObject() throws {
        let status = try coding.decode(SupermuxChangesStatusDTO.self, from: "{}")
        #expect(status.branch == nil)
        #expect(status.staged == nil)
        #expect(status.stashCount == nil)
    }

    @Test func changesStatusUnknownFieldTolerance() throws {
        let json = """
        {
          "workspace_id": "workspace:1",
          "branch": "main",
          "ahead": 1,
          "merge_conflict_hint": {"future": true},
          "staged": [{"path": "a.swift", "kind": "modified", "hunk_count": 4}]
        }
        """
        let status = try coding.decode(SupermuxChangesStatusDTO.self, from: json)
        #expect(status.workspaceId == "workspace:1")
        #expect(status.ahead == 1)
        #expect(status.staged?.first?.path == "a.swift")
    }

    @Test func changedFileRoundTrips() throws {
        let file = SupermuxChangedFileDTO(path: "src/x.swift", oldPath: "src/y.swift", kind: "renamed")
        #expect(try coding.roundTrip(file) == file)
        let keys = try coding.encodedKeys(of: file)
        #expect(keys == ["path", "old_path", "kind"])
    }

    @Test func changedFileUnknownFieldTolerance() throws {
        let json = #"{"path": "a.txt", "kind": "added", "similarity": 90}"#
        let file = try coding.decode(SupermuxChangedFileDTO.self, from: json)
        #expect(file.path == "a.txt")
        #expect(file.kind == "added")
        #expect(file.oldPath == nil)
    }

    @Test func diffRoundTrips() throws {
        let diff = SupermuxDiffDTO(
            path: "src/x.swift",
            isBinary: false,
            diffText: "@@ -1 +1 @@\n-old\n+new"
        )
        #expect(try coding.roundTrip(diff) == diff)
        let keys = try coding.encodedKeys(of: diff)
        #expect(keys == ["path", "is_binary", "diff_text"])
    }

    @Test func diffUnknownFieldTolerance() throws {
        let json = #"{"path": "logo.png", "is_binary": true, "render_hint": "image"}"#
        let diff = try coding.decode(SupermuxDiffDTO.self, from: json)
        #expect(diff.isBinary == true)
        #expect(diff.diffText == nil)
    }

    @Test func commitRoundTrips() throws {
        let commit = SupermuxCommitDTO(
            sha: "0123456789abcdef0123456789abcdef01234567",
            shortSha: "0123456",
            author: "Dev",
            relativeDate: "2 hours ago",
            subject: "feat: add thing",
            isPushed: true
        )
        #expect(try coding.roundTrip(commit) == commit)
        let keys = try coding.encodedKeys(of: commit)
        #expect(keys == ["sha", "short_sha", "author", "relative_date", "subject", "is_pushed"])
    }

    @Test func commitUnknownFieldTolerance() throws {
        let json = #"{"sha": "abc123", "gpg_signature": "sig", "co_authors": []}"#
        let commit = try coding.decode(SupermuxCommitDTO.self, from: json)
        #expect(commit.sha == "abc123")
        #expect(commit.author == nil)
        #expect(commit.isPushed == nil)
    }
}

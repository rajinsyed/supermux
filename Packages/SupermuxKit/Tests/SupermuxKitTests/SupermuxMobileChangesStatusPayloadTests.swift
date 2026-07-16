import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// Wire-payload tests for the `mobile.supermux.changes.status` read path
/// (validation contract RPC-CHG-01): a temp git repository seeded with one
/// staged, one unstaged, and one untracked file plus upstream ahead/behind
/// and a stash entry maps EXACTLY into the `SupermuxChangesStatusDTO` wire
/// shape, and decodes back through the shared ``SupermuxWireJSON`` bridge.
// Serialized: shells out to real `git`.
@Suite(.serialized) struct SupermuxMobileChangesStatusPayloadTests {
    private let service = SupermuxGitChangesService()
    private let builder = SupermuxMobileChangesPayloadBuilder()

    // MARK: - RPC-CHG-01

    @Test func statusPayloadReflectsSeededRepoExactly() async throws {
        // Upstream: a normal repo cloned over file:// (same seeding pattern
        // as the worktree lifecycle fixtures).
        let origin = try GitFixture.makeFixtureRepo(prefix: "supermux-changes-origin")
        defer { GitFixture.cleanUp(origin) }
        let clone = try GitFixture.makeTempDirectory(prefix: "supermux-changes-clone")
        defer { GitFixture.cleanUp(clone) }
        try GitFixture.runGit(["clone", "file://\(origin)", clone], in: origin)
        try GitFixture.configureIdentity(in: clone)

        // Ahead 1: a local commit the upstream does not have.
        try GitFixture.write("local\n", to: "local.txt", in: clone)
        try GitFixture.runGit(["add", "local.txt"], in: clone)
        try GitFixture.commit("Local commit", in: clone)
        // Behind 1: an upstream commit fetched but not merged.
        try GitFixture.write("remote\n", to: "remote.txt", in: origin)
        try GitFixture.runGit(["add", "remote.txt"], in: origin)
        try GitFixture.commit("Remote commit", in: origin)
        try GitFixture.runGit(["fetch", "origin"], in: clone)
        // Stash 1 (before staging, so the stash sweeps only this change).
        try GitFixture.write("stash me\n", to: "README.md", in: clone)
        try GitFixture.runGit(["stash", "push"], in: clone)
        // One staged, one unstaged, one untracked file.
        try GitFixture.write("staged\n", to: "staged.txt", in: clone)
        try GitFixture.runGit(["add", "staged.txt"], in: clone)
        try GitFixture.write("unstaged\n", to: "README.md", in: clone)
        try GitFixture.write("untracked\n", to: "untracked.txt", in: clone)

        let snapshot = await service.status(repoPath: clone)
        let payload = try builder.status(workspaceId: "workspace-1", snapshot: snapshot)

        #expect(payload["workspace_id"] as? String == "workspace-1")
        #expect(payload["is_repository"] as? Bool == true)
        #expect(payload["branch"] as? String == "main")
        #expect(payload["upstream_branch"] as? String == "origin/main")
        #expect(payload["ahead"] as? Int == 1)
        #expect(payload["behind"] as? Int == 1)
        #expect(payload["stash_count"] as? Int == 1)

        // The three arrays must match exactly.
        let status = try SupermuxWireJSON().decode(SupermuxChangesStatusDTO.self, from: payload)
        #expect(status.staged == [
            SupermuxChangedFileDTO(path: "staged.txt", oldPath: nil, kind: "added"),
        ])
        #expect(status.unstaged == [
            SupermuxChangedFileDTO(path: "README.md", oldPath: nil, kind: "modified"),
        ])
        #expect(status.untracked == [
            SupermuxChangedFileDTO(path: "untracked.txt", oldPath: nil, kind: "untracked"),
        ])
    }

    @Test func nonRepositoryDirectoryReportsIsRepositoryFalse() async throws {
        let plain = try GitFixture.makeTempDirectory(prefix: "supermux-changes-plain")
        defer { GitFixture.cleanUp(plain) }

        let snapshot = await service.status(repoPath: plain)
        let payload = try builder.status(workspaceId: "workspace-2", snapshot: snapshot)

        #expect(payload["is_repository"] as? Bool == false)
        #expect(payload["branch"] == nil)
        #expect((payload["staged"] as? [Any])?.isEmpty == true)
        #expect(payload["stash_count"] as? Int == 0)
    }

    // MARK: - Diff payload mapping

    @Test func diffPayloadCarriesWireKeys() throws {
        let payload = try builder.diff(
            path: "src/x.swift",
            diff: SupermuxGitFileDiff(isBinary: false, text: "@@ -1 +1 @@", truncated: true)
        )
        #expect(payload["path"] as? String == "src/x.swift")
        #expect(payload["is_binary"] as? Bool == false)
        #expect(payload["diff_text"] as? String == "@@ -1 +1 @@")
        #expect(payload["truncated"] as? Bool == true)
    }

    @Test func binaryDiffPayloadOmitsDiffText() throws {
        let payload = try builder.diff(
            path: "logo.png",
            diff: SupermuxGitFileDiff(isBinary: true, text: nil, truncated: false)
        )
        #expect(payload["is_binary"] as? Bool == true)
        #expect(payload["diff_text"] == nil)
    }
}

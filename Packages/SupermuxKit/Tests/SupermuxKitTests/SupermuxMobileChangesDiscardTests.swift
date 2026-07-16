import Foundation
import Testing

@testable import SupermuxKit

/// Disk-verified tests for the mobile stage → unstage → discard flow
/// (validation contract RPC-CHG-03): the git index and working tree are
/// checked with real `git` after each mutation, and discard restores HEAD
/// content for tracked files while deleting untracked ones — exactly the
/// desktop `SupermuxChangesModel` semantics, because the SAME
/// ``SupermuxGitChangesService`` mutations run underneath.
// Serialized: shells out to real `git`.
@Suite(.serialized) struct SupermuxMobileChangesDiscardTests {
    private let service = SupermuxGitChangesService()

    private func stagedNames(in root: String) throws -> [String] {
        try GitFixture.runGit(["diff", "--cached", "--name-only"], in: root)
            .split(separator: "\n").map(String.init)
    }

    // MARK: - RPC-CHG-03

    @Test func stageUnstageDiscardFlowVerifiedOnDisk() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-changes-discard")
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("changed\n", to: "README.md", in: root)
        try GitFixture.write("extra\n", to: "extra.txt", in: root)

        // stage {paths} → both paths land in the index.
        try await service.stage(repoPath: root, paths: ["README.md", "extra.txt"])
        #expect(try stagedNames(in: root).sorted() == ["README.md", "extra.txt"])

        // unstage {paths} → index empty again, worktree changes intact.
        try await service.unstage(repoPath: root, paths: ["README.md", "extra.txt"])
        #expect(try stagedNames(in: root).isEmpty)
        #expect(try GitFixture.read("README.md", in: root) == "changed\n")

        // discard {paths} → mac re-validates against a fresh snapshot,
        // then tracked files restore HEAD content and untracked files are
        // deleted (the desktop discard path, mirrored exactly).
        let snapshot = await service.status(repoPath: root)
        let resolution = SupermuxMobileChangesDiscard.resolve(
            paths: ["README.md", "extra.txt"], in: snapshot
        )
        guard case let .changes(changes) = resolution else {
            Issue.record("expected both paths to resolve to current changes")
            return
        }
        for change in changes {
            try await service.discard(repoPath: root, change: change)
        }
        #expect(try GitFixture.read("README.md", in: root) == "fixture\n")
        let extraPath = (root as NSString).appendingPathComponent("extra.txt")
        #expect(!FileManager.default.fileExists(atPath: extraPath))
        let after = await service.status(repoPath: root)
        #expect(after.totalChangeCount == 0)
    }

    @Test func discardingOnePathLeavesADirtySiblingUntouched() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-changes-discard-subset")
        defer { GitFixture.cleanUp(root) }
        // A second tracked file committed alongside the fixture root.
        try GitFixture.write("base other\n", to: "other.txt", in: root)
        try GitFixture.runGit(["add", "other.txt"], in: root)
        try GitFixture.commit("Add other", in: root)
        // Both tracked files dirtied in the working tree.
        try GitFixture.write("changed readme\n", to: "README.md", in: root)
        try GitFixture.write("changed other\n", to: "other.txt", in: root)

        // Discard ONLY README.md through the mobile resolve → discard path.
        let snapshot = await service.status(repoPath: root)
        let resolution = SupermuxMobileChangesDiscard.resolve(paths: ["README.md"], in: snapshot)
        guard case let .changes(changes) = resolution else {
            Issue.record("expected README.md to resolve to a current change")
            return
        }
        #expect(changes.count == 1)
        for change in changes {
            try await service.discard(repoPath: root, change: change)
        }

        // README restored to HEAD; the dirty sibling is untouched. A resolve()
        // that over-returned (every change for a single-path request) would
        // wrongly discard other.txt too — silent data loss.
        #expect(try GitFixture.read("README.md", in: root) == "fixture\n")
        #expect(try GitFixture.read("other.txt", in: root) == "changed other\n")
    }

    // MARK: - Re-validation

    @Test func unknownPathsResolveToUnknownWithoutMutating() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-changes-discard-unknown")
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("changed\n", to: "README.md", in: root)

        let snapshot = await service.status(repoPath: root)
        let resolution = SupermuxMobileChangesDiscard.resolve(
            paths: ["README.md", "ghost.txt"], in: snapshot
        )

        #expect(resolution == .unknownPaths(["ghost.txt"]))
        // Nothing was discarded: the modification is still on disk.
        #expect(try GitFixture.read("README.md", in: root) == "changed\n")
    }

    @Test func duplicatePathsResolveOnce() async throws {
        let snapshot = SupermuxGitStatusSnapshot(
            isRepository: true,
            branch: "main",
            upstreamBranch: nil,
            ahead: 0,
            behind: 0,
            staged: [],
            unstaged: [SupermuxGitFileChange(path: "a.txt", oldPath: nil, kind: .modified)],
            untracked: []
        )
        let resolution = SupermuxMobileChangesDiscard.resolve(
            paths: ["a.txt", "a.txt"], in: snapshot
        )
        #expect(resolution == .changes([
            SupermuxGitFileChange(path: "a.txt", oldPath: nil, kind: .modified),
        ]))
    }

    /// A path that is untracked wins over a same-named staged entry so the
    /// discard deletes the file rather than no-op checking out the index.
    @Test func untrackedEntryWinsOverStagedEntry() {
        let snapshot = SupermuxGitStatusSnapshot(
            isRepository: true,
            branch: "main",
            upstreamBranch: nil,
            ahead: 0,
            behind: 0,
            staged: [SupermuxGitFileChange(path: "b.txt", oldPath: nil, kind: .added)],
            unstaged: [],
            untracked: [SupermuxGitFileChange(path: "b.txt", oldPath: nil, kind: .untracked)]
        )
        let resolution = SupermuxMobileChangesDiscard.resolve(paths: ["b.txt"], in: snapshot)
        #expect(resolution == .changes([
            SupermuxGitFileChange(path: "b.txt", oldPath: nil, kind: .untracked),
        ]))
    }
}

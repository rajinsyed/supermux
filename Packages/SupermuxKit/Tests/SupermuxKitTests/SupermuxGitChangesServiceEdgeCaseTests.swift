import Foundation
import Testing

import SupermuxKit

/// Integration tests for `SupermuxGitChangesService` edge cases: conflicted
/// files and unborn-branch (no commits yet) repositories. Split from
/// `SupermuxGitChangesServiceTests` to respect that file's length budget.
///
/// Serialized for the same reason as the main suite: shells out to real `git`.
@Suite(.serialized) struct SupermuxGitChangesServiceEdgeCaseTests {
    private let service = SupermuxGitChangesService()

    // MARK: - Fixture helpers (shared implementation in `GitFixture`)

    private func makeFixtureRepo() throws -> String {
        try GitFixture.makeFixtureRepo(prefix: "supermux-changes-edge-tests")
    }

    /// Creates a temp git repository with NO commits (unborn `main`).
    private func makeUnbornRepo() throws -> String {
        let root = try GitFixture.makeTempDirectory(prefix: "supermux-changes-edge-tests")
        try GitFixture.runGit(["init", "-b", "main"], in: root)
        try GitFixture.configureIdentity(in: root)
        return root
    }

    /// Builds a repo with `file.txt` in a merge-conflicted (unmerged) state.
    private func makeConflictedRepo() throws -> String {
        let root = try makeFixtureRepo()
        try GitFixture.write("base\n", to: "file.txt", in: root)
        try GitFixture.runGit(["add", "file.txt"], in: root)
        try GitFixture.commit("Add file", in: root)
        try GitFixture.runGit(["checkout", "-b", "feature"], in: root)
        try GitFixture.write("feature\n", to: "file.txt", in: root)
        try GitFixture.runGit(["add", "file.txt"], in: root)
        try GitFixture.commit("Feature edit", in: root)
        try GitFixture.runGit(["checkout", "main"], in: root)
        try GitFixture.write("main\n", to: "file.txt", in: root)
        try GitFixture.runGit(["add", "file.txt"], in: root)
        try GitFixture.commit("Main edit", in: root)
        // The merge fails with a conflict; that non-zero exit is the fixture.
        _ = try? GitFixture.runGit(["merge", "feature"], in: root)
        return root
    }

    // MARK: - Conflicted discard

    @Test func discardConflictedFileRestoresHEADContentAndClearsConflict() async throws {
        let root = try makeConflictedRepo()
        defer { GitFixture.cleanUp(root) }

        let before = await service.status(repoPath: root)
        let conflicted = try #require(
            before.unstaged.first(where: { $0.kind == .conflicted && $0.path == "file.txt" }),
            "fixture must produce a conflicted file.txt"
        )

        // Plain `git checkout -- file.txt` refuses unmerged paths; discard must
        // still succeed and restore HEAD's (main's) content.
        try await service.discard(repoPath: root, change: conflicted)

        #expect(try GitFixture.read("file.txt", in: root) == "main\n")
        let after = await service.status(repoPath: root)
        #expect(!after.hasConflicts)
        #expect(!after.unstaged.contains(where: { $0.path == "file.txt" && $0.kind == .conflicted }))
    }

    /// Builds a repo where `conflict.txt` is deleted-by-us (`u DU`): `HEAD`
    /// deleted the file while the merged branch modified it, so the merge
    /// leaves the branch's version in the working tree.
    private func makeDeletedByUsConflictRepo() throws -> String {
        let root = try makeFixtureRepo()
        try GitFixture.write("base\n", to: "conflict.txt", in: root)
        try GitFixture.runGit(["add", "conflict.txt"], in: root)
        try GitFixture.commit("Add conflict file", in: root)
        try GitFixture.runGit(["checkout", "-b", "feature"], in: root)
        try GitFixture.write("feature edit\n", to: "conflict.txt", in: root)
        try GitFixture.runGit(["add", "conflict.txt"], in: root)
        try GitFixture.commit("Feature edit", in: root)
        try GitFixture.runGit(["checkout", "main"], in: root)
        try GitFixture.runGit(["rm", "-q", "conflict.txt"], in: root)
        try GitFixture.commit("Delete conflict file", in: root)
        // The merge fails with a modify/delete conflict; that is the fixture.
        _ = try? GitFixture.runGit(["merge", "feature"], in: root)
        return root
    }

    /// A conflicted path absent from `HEAD` has no content to `checkout HEAD`
    /// from (and `git restore --source=HEAD` errors "path is unmerged");
    /// discard must fall back to `git rm -f`, clearing the unmerged entry and
    /// removing the working file.
    @Test func discardDeletedByUsConflictRemovesFileAndClearsConflict() async throws {
        let root = try makeDeletedByUsConflictRepo()
        defer { GitFixture.cleanUp(root) }

        let before = await service.status(repoPath: root)
        let conflicted = try #require(
            before.unstaged.first(where: { $0.kind == .conflicted && $0.path == "conflict.txt" }),
            "fixture must produce a DU-conflicted conflict.txt"
        )

        try await service.discard(repoPath: root, change: conflicted)

        let after = await service.status(repoPath: root)
        #expect(!after.hasConflicts)
        #expect(!after.unstaged.contains(where: { $0.path == "conflict.txt" }))
        #expect(!FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent("conflict.txt")
        ))
    }

    // MARK: - Unborn branch (no commits)

    @Test func unstageAllWorksOnUnbornBranch() async throws {
        let root = try makeUnbornRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("hello\n", to: "new.txt", in: root)
        try GitFixture.runGit(["add", "new.txt"], in: root)

        // `git reset -q HEAD` exits 128 on an unborn branch; unstageAll must
        // not depend on HEAD resolving.
        try await service.unstageAll(repoPath: root)

        let status = await service.status(repoPath: root)
        #expect(status.staged.isEmpty)
        #expect(status.untracked.map(\.path) == ["new.txt"])
    }

    @Test func discardAllWorksOnUnbornBranch() async throws {
        let root = try makeUnbornRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("staged\n", to: "staged.txt", in: root)
        try GitFixture.runGit(["add", "staged.txt"], in: root)
        try GitFixture.write("loose\n", to: "loose.txt", in: root)

        // `git reset --hard HEAD` exits 128 on an unborn branch; discardAll
        // must fall back to unstaging + clean.
        try await service.discardAll(repoPath: root)

        let status = await service.status(repoPath: root)
        #expect(status.totalChangeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("staged.txt")))
        #expect(!FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("loose.txt")))
    }

    @Test func discardAllOnBornBranchStillRestoresTrackedContent() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        try GitFixture.write("changed\n", to: "README.md", in: root)
        try GitFixture.write("loose\n", to: "loose.txt", in: root)

        try await service.discardAll(repoPath: root)

        #expect(try GitFixture.read("README.md", in: root) == "fixture\n")
        let status = await service.status(repoPath: root)
        #expect(status.totalChangeCount == 0)
    }

    /// A single non-UTF-8 filename anywhere in the repo makes the `-z` status
    /// output undecodable as strict UTF-8 (git prints path bytes verbatim),
    /// which used to nil the whole capture and falsely report "not a
    /// repository" — disabling every panel action. The lossy fallback must
    /// keep the repo recognized with the mangled name still surfaced.
    @Test func statusSurvivesNonUTF8PathInIndex() async throws {
        let root = try makeFixtureRepo()
        defer { GitFixture.cleanUp(root) }
        // Register an index entry named latin-1 "café.txt" (raw 0xE9 — invalid
        // UTF-8). Such a name cannot be checked out on APFS, so it is planted
        // straight into the index; Swift Strings cannot carry the byte either,
        // hence the printf detour through bash.
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = [
            "-c",
            "cd \"$1\" && git update-index --add --cacheinfo " +
                "100644,$(git hash-object -w README.md),\"$(printf 'caf\\351.txt')\"",
            "bash",
            root,
        ]
        try bash.run()
        bash.waitUntilExit()
        #expect(bash.terminationStatus == 0)

        let snapshot = await service.status(repoPath: root)

        #expect(snapshot.isRepository)
        #expect(snapshot.totalChangeCount > 0)
        // The mangled name still surfaces (its invalid byte replaced), so the
        // one broken file degrades instead of the whole panel.
        let allPaths = (snapshot.staged + snapshot.unstaged + snapshot.untracked).map(\.path)
        #expect(allPaths.contains { $0.hasPrefix("caf") })
    }
}

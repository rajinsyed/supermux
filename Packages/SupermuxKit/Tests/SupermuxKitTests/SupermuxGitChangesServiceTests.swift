import Foundation
import Testing

import SupermuxKit

/// Integration tests for `SupermuxGitChangesService` against real temporary
/// git repositories. Every test builds its own fixture repository so the
/// suite stays parallel-safe, and removes it on exit.
///
/// Serialized: shells out to real `git`. Run fully parallel alongside the other
/// git-integration suites, peak subprocess concurrency was high enough to flake
/// (commits and `rev-parse` intermittently failed); serializing keeps it low.
@Suite(.serialized) struct SupermuxGitChangesServiceTests {
    private let service = SupermuxGitChangesService()

    // MARK: - Fixture helpers

    /// A git invocation made by the fixture helper failed.
    private enum FixtureError: Error {
        case gitFailed(arguments: [String], message: String)
    }

    /// Creates a unique temporary directory and returns its path,
    /// standardized the same way the services normalize paths.
    private func makeTempDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-changes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url.path as NSString).standardizingPath
    }

    /// Creates a temp git repository on `main` with one committed `README.md`.
    /// Commit signing is disabled locally so service-side commits also work
    /// on machines with global `commit.gpgsign` enabled.
    private func makeFixtureRepo() throws -> String {
        let root = try makeTempDirectory()
        try runGit(["init", "-b", "main"], in: root)
        try runGit(["config", "--local", "user.email", "tests@supermux.invalid"], in: root)
        try runGit(["config", "--local", "user.name", "Supermux Tests"], in: root)
        try runGit(["config", "--local", "commit.gpgsign", "false"], in: root)
        try write("fixture\n", to: "README.md", in: root)
        try runGit(["add", "."], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Initial commit"], in: root)
        return root
    }

    /// Creates a bare repository on `main` to serve as a push remote.
    private func makeBareRemote() throws -> String {
        let remote = try makeTempDirectory()
        try runGit(["init", "--bare", "-b", "main"], in: remote)
        return remote
    }

    /// Writes `content` to `relativePath` inside `root`.
    private func write(_ content: String, to relativePath: String, in root: String) throws {
        let path = (root as NSString).appendingPathComponent(relativePath)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Reads the contents of `relativePath` inside `root`.
    private func read(_ relativePath: String, in root: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(relativePath)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Runs git synchronously via `Process` (test-only helper) and returns
    /// its standard output; throws on a non-zero exit.
    @discardableResult
    private func runGit(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.gitFailed(
                arguments: arguments,
                message: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    /// Best-effort removal of a fixture directory.
    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Status

    @Test func statusOnPlainDirectoryReportsNotARepository() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let snapshot = await service.status(repoPath: dir)

        #expect(snapshot.isRepository == false)
        #expect(snapshot == .notARepository)
    }

    @Test func statusOnCleanRepoReportsBranchAndEmptyLists() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }

        let snapshot = await service.status(repoPath: root)

        #expect(snapshot.isRepository)
        #expect(snapshot.branch == "main")
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.unstaged.isEmpty)
        #expect(snapshot.untracked.isEmpty)
        #expect(snapshot.totalChangeCount == 0)
    }

    // MARK: - Staging

    @Test func stageAndUnstageMoveNewFileBetweenLists() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("new\n", to: "new.txt", in: root)

        let beforeStage = await service.status(repoPath: root)
        let untracked = try #require(beforeStage.untracked.first { $0.path == "new.txt" })
        #expect(untracked.kind == .untracked)
        #expect(beforeStage.staged.isEmpty)

        try await service.stage(repoPath: root, paths: ["new.txt"])
        let afterStage = await service.status(repoPath: root)
        let staged = try #require(afterStage.staged.first { $0.path == "new.txt" })
        #expect(staged.kind == .added)
        #expect(afterStage.untracked.isEmpty)

        try await service.unstage(repoPath: root, paths: ["new.txt"])
        let afterUnstage = await service.status(repoPath: root)
        // `git reset HEAD` on a never-committed file makes it untracked again.
        #expect(afterUnstage.staged.isEmpty)
        #expect(afterUnstage.untracked.contains { $0.path == "new.txt" })
    }

    @Test func stageAllThenCommitProducesCleanStatus() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("updated\n", to: "README.md", in: root)

        let dirty = await service.status(repoPath: root)
        let modified = try #require(dirty.unstaged.first { $0.path == "README.md" })
        #expect(modified.kind == .modified)
        #expect(dirty.staged.isEmpty)

        try await service.stageAll(repoPath: root)
        let staged = await service.status(repoPath: root)
        #expect(staged.staged.contains { $0.path == "README.md" })
        #expect(staged.unstaged.isEmpty)

        try await service.commit(repoPath: root, message: "Update README")
        let clean = await service.status(repoPath: root)
        #expect(clean.totalChangeCount == 0)
        let subject = try runGit(["log", "-1", "--format=%s"], in: root)
        #expect(subject.trimmingCharacters(in: .whitespacesAndNewlines) == "Update README")
    }

    @Test func unstageAllEmptiesStagedList() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("one\n", to: "one.txt", in: root)
        try write("two\n", to: "two.txt", in: root)
        try write("updated\n", to: "README.md", in: root)
        try await service.stageAll(repoPath: root)

        let staged = await service.status(repoPath: root)
        #expect(staged.staged.count == 3)

        try await service.unstageAll(repoPath: root)

        let after = await service.status(repoPath: root)
        #expect(after.staged.isEmpty)
        #expect(after.untracked.contains { $0.path == "one.txt" })
        #expect(after.untracked.contains { $0.path == "two.txt" })
        #expect(after.unstaged.contains { $0.path == "README.md" })
    }

    // MARK: - Discard

    @Test func discardRestoresModifiedTrackedFileContent() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("v1\n", to: "file.txt", in: root)
        try runGit(["add", "file.txt"], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Add file"], in: root)
        try write("v2\n", to: "file.txt", in: root)

        let snapshot = await service.status(repoPath: root)
        let change = try #require(snapshot.unstaged.first { $0.path == "file.txt" })

        try await service.discard(repoPath: root, change: change)

        #expect(try read("file.txt", in: root) == "v1\n")
        let after = await service.status(repoPath: root)
        #expect(after.totalChangeCount == 0)
    }

    @Test func discardDeletesUntrackedFileFromDisk() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("scratch\n", to: "scratch.txt", in: root)

        let snapshot = await service.status(repoPath: root)
        let change = try #require(snapshot.untracked.first { $0.path == "scratch.txt" })
        #expect(change.kind == .untracked)

        try await service.discard(repoPath: root, change: change)

        let fullPath = (root as NSString).appendingPathComponent("scratch.txt")
        #expect(FileManager.default.fileExists(atPath: fullPath) == false)
        let after = await service.status(repoPath: root)
        #expect(after.untracked.isEmpty)
    }

    /// Regression: discarding an unstaged rename must restore the original path
    /// *and* remove the renamed-to file from disk. The bug restored `old.txt`
    /// from HEAD but left the moved `new.txt` sitting in the working tree.
    ///
    /// Fixture: commit `old.txt`, `git mv` it to `new.txt`, then `git reset -N`
    /// so the rename appears as an unstaged worktree change (`.R` status pair,
    /// reported by the parser as a `.renamed` entry in `unstaged`). The original
    /// `old.txt` index entry survives `reset -N`, so the service's
    /// `git checkout -- old.txt` succeeds; because `new.txt` is not a tracked
    /// HEAD path, the fix deletes it.
    @Test func discardUnstagedRenameRestoresOldPathAndRemovesNewFile() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("v1\n", to: "old.txt", in: root)
        try runGit(["add", "old.txt"], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Add old"], in: root)
        try runGit(["mv", "old.txt", "new.txt"], in: root)
        // `reset -N` unstages the rename while keeping `new.txt` intent-to-add,
        // so git reports a worktree-side rename instead of a staged one.
        try runGit(["reset", "-N", "-q", "HEAD", "--"], in: root)

        let snapshot = await service.status(repoPath: root)
        let change = try #require(snapshot.unstaged.first { $0.path == "new.txt" })
        #expect(change.kind == .renamed)
        #expect(change.path == "new.txt")
        #expect(change.oldPath == "old.txt")

        try await service.discard(repoPath: root, change: change)

        let oldPath = (root as NSString).appendingPathComponent("old.txt")
        let newPath = (root as NSString).appendingPathComponent("new.txt")
        #expect(FileManager.default.fileExists(atPath: oldPath))
        #expect(try read("old.txt", in: root) == "v1\n")
        #expect(FileManager.default.fileExists(atPath: newPath) == false)
    }

    /// `discardAll` returns the working tree to `HEAD`: staged and unstaged
    /// modifications to tracked files are reverted, untracked files are deleted,
    /// and ignored files are left untouched (no `-x` on `git clean`).
    @Test func discardAllResetsTrackedChangesAndRemovesUntrackedButKeepsIgnored() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        // A tracked file with committed content we can assert is restored.
        try write("v1\n", to: "tracked.txt", in: root)
        // An ignored directory whose artifact must survive the discard.
        try write("build/\n", to: ".gitignore", in: root)
        try runGit(["add", "tracked.txt", ".gitignore"], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Add tracked + gitignore"], in: root)
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent("build"),
            withIntermediateDirectories: true
        )
        try write("artifact\n", to: "build/out.o", in: root)

        // A staged modification, a further unstaged modification on top of it,
        // and a brand-new untracked file.
        try write("v2\n", to: "tracked.txt", in: root)
        try runGit(["add", "tracked.txt"], in: root)
        try write("v3\n", to: "tracked.txt", in: root)
        try write("scratch\n", to: "scratch.txt", in: root)

        let dirty = await service.status(repoPath: root)
        #expect(dirty.totalChangeCount > 0)

        try await service.discardAll(repoPath: root)

        let clean = await service.status(repoPath: root)
        #expect(clean.totalChangeCount == 0)
        #expect(try read("tracked.txt", in: root) == "v1\n")
        #expect(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent("scratch.txt")
        ) == false)
        // Ignored artifacts are preserved because `git clean` runs without `-x`.
        #expect(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent("build/out.o")
        ))
    }

    // MARK: - Unpushed commits

    @Test func unpushedCommitsReturnsCommitsAheadOfUpstream() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        let remote = try makeBareRemote()
        defer { cleanUp(remote) }
        try runGit(["remote", "add", "origin", remote], in: root)
        try runGit(["push", "-u", "origin", "main"], in: root)
        try write("a\n", to: "a.txt", in: root)
        try runGit(["add", "a.txt"], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Local one"], in: root)
        try write("b\n", to: "b.txt", in: root)
        try runGit(["add", "b.txt"], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Local two"], in: root)

        let commits = await service.unpushedCommits(repoPath: root, hasUpstream: true, limit: 10)

        #expect(commits.count == 2)
        #expect(commits[0].subject == "Local two")
        #expect(commits[1].subject == "Local one")
        #expect(!commits.contains { $0.subject == "Initial commit" })
        #expect(commits[0].author == "Supermux Tests")
    }

    @Test func unpushedCommitsAfterPushReturnsNone() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        let remote = try makeBareRemote()
        defer { cleanUp(remote) }
        try runGit(["remote", "add", "origin", remote], in: root)
        try runGit(["push", "-u", "origin", "main"], in: root)

        let commits = await service.unpushedCommits(repoPath: root, hasUpstream: true, limit: 10)

        #expect(commits.isEmpty)
    }

    @Test func unpushedCommitsHonorsLimit() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        let remote = try makeBareRemote()
        defer { cleanUp(remote) }
        try runGit(["remote", "add", "origin", remote], in: root)
        try runGit(["push", "-u", "origin", "main"], in: root)
        for index in 1...3 {
            try write("\(index)\n", to: "f\(index).txt", in: root)
            try runGit(["add", "f\(index).txt"], in: root)
            try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Commit \(index)"], in: root)
        }

        let commits = await service.unpushedCommits(repoPath: root, hasUpstream: true, limit: 2)

        #expect(commits.count == 2)
        #expect(commits[0].subject == "Commit 3")
        #expect(commits[1].subject == "Commit 2")
    }

    @Test func unpushedCommitsWithoutUpstreamReturnsLocalCommits() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("a\n", to: "a.txt", in: root)
        try runGit(["add", "a.txt"], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Second"], in: root)

        // No remote at all → nothing is pushed → both commits are unpushed.
        let commits = await service.unpushedCommits(repoPath: root, hasUpstream: false, limit: 10)

        #expect(commits.count == 2)
        #expect(commits[0].subject == "Second")
        #expect(commits[1].subject == "Initial commit")
    }

    @Test func unpushedCommitsOnPlainDirectoryReturnsNone() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let commits = await service.unpushedCommits(repoPath: dir, hasUpstream: false, limit: 10)

        #expect(commits.isEmpty)
    }

    // MARK: - Stash

    @Test func stashTrackedChangeClearsWorkingTreeAndPopRestoresIt() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("stashed\n", to: "README.md", in: root)

        let beforeStash = await service.status(repoPath: root)
        #expect(beforeStash.hasTrackedChanges)
        #expect(beforeStash.stashEntryCount == 0)

        try await service.stash(repoPath: root, includeUntracked: false)

        let afterStash = await service.status(repoPath: root)
        #expect(afterStash.totalChangeCount == 0)
        #expect(afterStash.stashEntryCount == 1)
        // The committed content is back in the working tree while the edit waits
        // on the stash.
        #expect(try read("README.md", in: root) == "fixture\n")

        try await service.popStash(repoPath: root)

        let afterPop = await service.status(repoPath: root)
        #expect(afterPop.stashEntryCount == 0)
        #expect(afterPop.unstaged.contains { $0.path == "README.md" })
        #expect(try read("README.md", in: root) == "stashed\n")
    }

    @Test func stashWithoutUntrackedLeavesUntrackedFilesOnDisk() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("edit\n", to: "README.md", in: root)
        try write("scratch\n", to: "scratch.txt", in: root)

        try await service.stash(repoPath: root, includeUntracked: false)

        let after = await service.status(repoPath: root)
        // The tracked edit was stashed; the untracked file is untouched.
        #expect(after.unstaged.isEmpty)
        #expect(after.untracked.contains { $0.path == "scratch.txt" })
        #expect(after.stashEntryCount == 1)
        let scratchPath = (root as NSString).appendingPathComponent("scratch.txt")
        #expect(FileManager.default.fileExists(atPath: scratchPath))
    }

    @Test func stashIncludeUntrackedRemovesUntrackedFileAndPopRestoresIt() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        try write("scratch\n", to: "scratch.txt", in: root)

        try await service.stash(repoPath: root, includeUntracked: true)

        let scratchPath = (root as NSString).appendingPathComponent("scratch.txt")
        let afterStash = await service.status(repoPath: root)
        #expect(afterStash.totalChangeCount == 0)
        #expect(afterStash.stashEntryCount == 1)
        #expect(FileManager.default.fileExists(atPath: scratchPath) == false)

        try await service.popStash(repoPath: root)

        let afterPop = await service.status(repoPath: root)
        #expect(afterPop.stashEntryCount == 0)
        #expect(afterPop.untracked.contains { $0.path == "scratch.txt" })
        #expect(FileManager.default.fileExists(atPath: scratchPath))
    }

    @Test func statusReportsStashEntryCount() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }

        #expect(await service.status(repoPath: root).stashEntryCount == 0)

        try write("one\n", to: "README.md", in: root)
        try await service.stash(repoPath: root, includeUntracked: false)
        try write("two\n", to: "README.md", in: root)
        try await service.stash(repoPath: root, includeUntracked: false)

        #expect(await service.status(repoPath: root).stashEntryCount == 2)
    }

    @Test func popStashWithoutStashThrows() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }

        await #expect(throws: SupermuxGitError.self) {
            try await service.popStash(repoPath: root)
        }
    }

    // MARK: - Incoming commits

    @Test func incomingCommitsReturnsCommitsBehindUpstream() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        let remote = try makeBareRemote()
        defer { cleanUp(remote) }
        try runGit(["remote", "add", "origin", remote], in: root)
        try runGit(["push", "-u", "origin", "main"], in: root)
        // Advance the branch and push so origin/main carries the commit...
        try write("a\n", to: "a.txt", in: root)
        try runGit(["add", "a.txt"], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Remote one"], in: root)
        try runGit(["push"], in: root)
        // ...then move local HEAD back, making that commit "incoming" again.
        try runGit(["reset", "--hard", "HEAD~1"], in: root)

        let snapshot = await service.status(repoPath: root)
        #expect(snapshot.behind == 1)

        let commits = await service.incomingCommits(repoPath: root, limit: 10)
        #expect(commits.count == 1)
        #expect(commits[0].subject == "Remote one")
        #expect(!commits.contains { $0.subject == "Initial commit" })
    }

    @Test func incomingCommitsHonorsLimit() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        let remote = try makeBareRemote()
        defer { cleanUp(remote) }
        try runGit(["remote", "add", "origin", remote], in: root)
        try runGit(["push", "-u", "origin", "main"], in: root)
        for index in 1...3 {
            try write("\(index)\n", to: "f\(index).txt", in: root)
            try runGit(["add", "f\(index).txt"], in: root)
            try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Commit \(index)"], in: root)
        }
        try runGit(["push"], in: root)
        try runGit(["reset", "--hard", "HEAD~3"], in: root)

        let commits = await service.incomingCommits(repoPath: root, limit: 2)

        #expect(commits.count == 2)
        #expect(commits[0].subject == "Commit 3")
        #expect(commits[1].subject == "Commit 2")
    }

    @Test func incomingCommitsWithoutUpstreamReturnsNone() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }

        // No upstream → nothing is pullable, and there is no remotes fallback.
        let commits = await service.incomingCommits(repoPath: root, limit: 10)

        #expect(commits.isEmpty)
    }

    @Test func unpushedCountWithoutUpstreamCountsLocalThenZeroAfterPush() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }

        // No remote yet → every local commit is unpushed.
        #expect(await service.unpushedCountWithoutUpstream(repoPath: root) == 1)
        try write("a\n", to: "a.txt", in: root)
        try runGit(["add", "a.txt"], in: root)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Second"], in: root)
        #expect(await service.unpushedCountWithoutUpstream(repoPath: root) == 2)

        // After pushing, those commits live on a remote-tracking branch, so the
        // "--not --remotes" count drops to zero.
        let remote = try makeBareRemote()
        defer { cleanUp(remote) }
        try runGit(["remote", "add", "origin", remote], in: root)
        try runGit(["push", "-u", "origin", "main"], in: root)

        #expect(await service.unpushedCountWithoutUpstream(repoPath: root) == 0)
    }

    // MARK: - Fetch

    /// `fetch` updates the remote-tracking ref so a commit pushed elsewhere
    /// becomes visible as "behind" / incoming without the user pulling.
    @Test func fetchUpdatesBehindFromRemote() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        let remote = try makeBareRemote()
        defer { cleanUp(remote) }
        try runGit(["remote", "add", "origin", remote], in: root)
        try runGit(["push", "-u", "origin", "main"], in: root)

        // Simulate someone else pushing: clone, commit, push.
        let otherParent = try makeTempDirectory()
        defer { cleanUp(otherParent) }
        try runGit(["clone", remote, "clone"], in: otherParent)
        let other = (otherParent as NSString).appendingPathComponent("clone")
        try runGit(["config", "--local", "user.email", "other@supermux.invalid"], in: other)
        try runGit(["config", "--local", "user.name", "Other Dev"], in: other)
        try runGit(["config", "--local", "commit.gpgsign", "false"], in: other)
        try write("elsewhere\n", to: "elsewhere.txt", in: other)
        try runGit(["add", "elsewhere.txt"], in: other)
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", "Pushed elsewhere"], in: other)
        try runGit(["push"], in: other)

        // Root has not fetched yet, so it still believes it is up to date.
        let before = await service.status(repoPath: root)
        #expect(before.behind == 0)

        let didFetch = await service.fetch(repoPath: root)
        #expect(didFetch)

        let after = await service.status(repoPath: root)
        #expect(after.behind == 1)
        let incoming = await service.incomingCommits(repoPath: root, limit: 10)
        #expect(incoming.first?.subject == "Pushed elsewhere")
    }

    @Test func fetchWithUnreachableRemoteReportsFailure() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }
        // origin points at a path that is not a repository → fetch fails fast
        // (and `core.askpass=true` keeps it from stalling on a prompt). The
        // failure is reported as `false` rather than thrown, so an auto-fetch
        // degrades quietly.
        try runGit(["remote", "add", "origin", "/nonexistent/supermux-not-a-repo"], in: root)

        let didFetch = await service.fetch(repoPath: root)

        #expect(didFetch == false)
    }

    // MARK: - Commit failures

    @Test func commitWithNothingStagedThrows() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }

        await #expect(throws: SupermuxGitError.self) {
            try await service.commit(repoPath: root, message: "Empty commit attempt")
        }
    }
}

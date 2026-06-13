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

    // MARK: - Commit failures

    @Test func commitWithNothingStagedThrows() async throws {
        let root = try makeFixtureRepo()
        defer { cleanUp(root) }

        await #expect(throws: SupermuxGitError.self) {
            try await service.commit(repoPath: root, message: "Empty commit attempt")
        }
    }
}

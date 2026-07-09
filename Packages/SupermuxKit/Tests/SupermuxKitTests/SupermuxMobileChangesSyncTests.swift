import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// Core tests for the mobile `changes.commit` / `changes.push` /
/// `changes.pull` / `changes.stash` / `changes.stash_pop` RPCs (validation
/// contract RPC-CHG-04 and RPC-CHG-05): the shared
/// ``SupermuxGitChangesService`` mutations run against a temp repository with
/// a `file://` remote, each sync invocation's captured git output maps into
/// the `{ok, log_lines}` wire payload, and the remote/stash state is verified
/// via git after every step.
// Serialized: shells out to real `git`. Alongside the other git-integration
// suites, subprocess concurrency can transiently drop a capture (the shared
// CommandRunner partial/empty-read artifact); one full-suite rerun is the
// documented remedy.
@Suite(.serialized) struct SupermuxMobileChangesSyncTests {
    private let service = SupermuxGitChangesService()
    private let builder = SupermuxMobileChangesPayloadBuilder()

    // MARK: - RPC-CHG-04 commit

    @Test func commitReturnsHeadShaMatchingGitLog() async throws {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-sync-commit")
        defer { GitFixture.cleanUp(repo) }
        try GitFixture.write("changed\n", to: "README.md", in: repo)
        try await service.stage(repoPath: repo, paths: ["README.md"])

        try await service.commit(repoPath: repo, message: "feat: mobile commit")
        let sha = try #require(await service.headCommitSha(repoPath: repo))

        // `git log -1` must show exactly this sha and message (RPC-CHG-04).
        let logged = try GitFixture.runGit(["log", "-1", "--format=%H%n%s"], in: repo)
            .split(separator: "\n").map(String.init)
        #expect(sha.count == 40)
        #expect(logged.first == sha)
        #expect(logged.last == "feat: mobile commit")
    }

    @Test func headCommitShaIsNilOutsideARepository() async throws {
        let plain = try GitFixture.makeTempDirectory(prefix: "supermux-sync-plain")
        defer { GitFixture.cleanUp(plain) }
        #expect(await service.headCommitSha(repoPath: plain) == nil)
    }

    // MARK: - RPC-CHG-05 push / pull / stash / stash_pop

    @Test func pushPullStashAndPopAgainstFileRemote() async throws {
        let (bare, clone) = try makeRemoteAndClone(prefix: "supermux-sync-flow")
        defer {
            GitFixture.cleanUp(bare)
            GitFixture.cleanUp(clone)
        }

        // Push: a local commit lands on the file:// remote, with log lines.
        try GitFixture.write("local\n", to: "local.txt", in: clone)
        try GitFixture.runGit(["add", "local.txt"], in: clone)
        try GitFixture.commit("Local commit", in: clone)
        let pushResult = try await service.push(repoPath: clone, hasUpstream: true)
        let pushLog = SupermuxMobileSyncLog.capture(pushResult)
        #expect(!pushLog.lines.isEmpty)
        let pushedSha = try GitFixture.runGit(["rev-parse", "HEAD"], in: clone)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSha = try GitFixture.runGit(["rev-parse", "main"], in: bare)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteSha == pushedSha)

        // Pull: a commit pushed by a second clone fast-forwards this one.
        let seeder = try GitFixture.makeTempDirectory(prefix: "supermux-sync-seeder")
        defer { GitFixture.cleanUp(seeder) }
        try GitFixture.runGit(["clone", "file://\(bare)", seeder], in: clone)
        try GitFixture.configureIdentity(in: seeder)
        try GitFixture.write("seeded\n", to: "seeded.txt", in: seeder)
        try GitFixture.runGit(["add", "seeded.txt"], in: seeder)
        try GitFixture.commit("Seeded commit", in: seeder)
        try GitFixture.runGit(["push"], in: seeder)
        let pullResult = try await service.pull(repoPath: clone)
        let pullLog = SupermuxMobileSyncLog.capture(pullResult)
        #expect(!pullLog.lines.isEmpty)
        let seededSha = try GitFixture.runGit(["rev-parse", "HEAD"], in: seeder)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cloneSha = try GitFixture.runGit(["rev-parse", "HEAD"], in: clone)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cloneSha == seededSha)

        // Stash: the tracked change moves into a stash entry carrying the
        // phone's message; the working tree restores committed content.
        try GitFixture.write("dirty\n", to: "local.txt", in: clone)
        let stashResult = try await service.stash(
            repoPath: clone, includeUntracked: false, message: "wip: from phone"
        )
        let stashLog = SupermuxMobileSyncLog.capture(stashResult)
        #expect(!stashLog.lines.isEmpty)
        let stashList = try GitFixture.runGit(["stash", "list"], in: clone)
        #expect(stashList.contains("wip: from phone"))
        #expect(try GitFixture.read("local.txt", in: clone) == "local\n")

        // Pop: the stash empties and the dirty content returns.
        let popResult = try await service.popStash(repoPath: clone)
        let popLog = SupermuxMobileSyncLog.capture(popResult)
        #expect(!popLog.lines.isEmpty)
        let emptiedList = try GitFixture.runGit(["stash", "list"], in: clone)
        #expect(emptiedList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(try GitFixture.read("local.txt", in: clone) == "dirty\n")
    }

    // MARK: - Log capture caps

    @Test func captureCombinesStdoutAndStderrDroppingBlankLines() {
        let capture = SupermuxMobileSyncLog.capture(
            stdout: "Updating abc..def\n\nFast-forward\n",
            stderr: "From file:///remote\r\n   abc..def  main -> origin/main\n"
        )
        #expect(capture.lines == [
            "Updating abc..def",
            "Fast-forward",
            "From file:///remote",
            "abc..def  main -> origin/main",
        ])
        #expect(!capture.truncated)
    }

    @Test func captureCapsLineCountAndFlagsTruncation() {
        let stdout = (1...150).map { "line \($0)" }.joined(separator: "\n")
        let capture = SupermuxMobileSyncLog.capture(stdout: stdout, stderr: nil)
        #expect(capture.lines.count == SupermuxMobileSyncLog.maxLines)
        #expect(capture.lines.first == "line 1")
        #expect(capture.lines.last == "line \(SupermuxMobileSyncLog.maxLines)")
        #expect(capture.truncated)
    }

    @Test func captureCapsOversizedLinesAndFlagsTruncation() {
        let long = String(repeating: "x", count: 1000)
        let capture = SupermuxMobileSyncLog.capture(stdout: long, stderr: nil)
        #expect(capture.lines.count == 1)
        #expect(capture.lines[0].count == SupermuxMobileSyncLog.maxLineCharacters)
        #expect(capture.truncated)
    }

    // MARK: - Sync payload shape

    @Test func syncPayloadCarriesOkAndLogLines() {
        let payload = builder.sync(log: SupermuxMobileSyncLogCapture(
            lines: ["Everything up-to-date"], truncated: false
        ))
        #expect(payload["ok"] as? Bool == true)
        #expect(payload["log_lines"] as? [String] == ["Everything up-to-date"])
        #expect(payload["log_truncated"] == nil)
    }

    @Test func syncPayloadFlagsTruncatedLogs() {
        let payload = builder.sync(log: SupermuxMobileSyncLogCapture(
            lines: ["a"], truncated: true
        ))
        #expect(payload["log_truncated"] as? Bool == true)
    }

    // MARK: - Fixture

    /// A bare `file://` remote (seeded with the standard fixture history) plus
    /// a working clone whose `main` tracks `origin/main`.
    private func makeRemoteAndClone(prefix: String) throws -> (bare: String, clone: String) {
        let seed = try GitFixture.makeFixtureRepo(prefix: "\(prefix)-seed")
        defer { GitFixture.cleanUp(seed) }
        let bare = try GitFixture.makeTempDirectory(prefix: "\(prefix)-remote")
        try GitFixture.runGit(["clone", "--bare", "file://\(seed)", bare], in: seed)
        let clone = try GitFixture.makeTempDirectory(prefix: "\(prefix)-clone")
        try GitFixture.runGit(["clone", "file://\(bare)", clone], in: seed)
        try GitFixture.configureIdentity(in: clone)
        return (bare, clone)
    }
}

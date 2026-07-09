import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// Core tests for the mobile `changes.history` RPC (validation contract
/// RPC-CHG-06): against a repository with more commits than one page, the
/// sha-cursor pagination yields non-overlapping pages, `next_cursor` resumes
/// exactly where the previous page ended, `is_pushed` flags reflect what is
/// on the `file://` remote, and incoming (pullable) commits ride the first
/// page.
// Serialized: shells out to real `git`. Alongside the other git-integration
// suites, subprocess concurrency can transiently drop a capture (the shared
// CommandRunner partial/empty-read artifact); one full-suite rerun is the
// documented remedy.
@Suite(.serialized) struct SupermuxMobileChangesHistoryTests {
    private let service = SupermuxGitChangesService()
    private let builder = SupermuxMobileChangesPayloadBuilder()

    // MARK: - RPC-CHG-06

    @Test func historyPagesDoNotOverlapAndMarkPushedState() async throws {
        let (bare, clone) = try makeRemoteAndClone(prefix: "supermux-history")
        defer {
            GitFixture.cleanUp(bare)
            GitFixture.cleanUp(clone)
        }
        // Three pushed commits on top of the pushed fixture root...
        for name in ["a", "b", "c"] {
            try addCommit("Pushed \(name)", file: "pushed-\(name).txt", in: clone)
        }
        try GitFixture.runGit(["push"], in: clone)
        // ...then three local-only commits. History (newest first) is:
        // local-3, local-2, local-1, Pushed c, Pushed b, Pushed a, Initial.
        for name in ["1", "2", "3"] {
            try addCommit("Local \(name)", file: "local-\(name).txt", in: clone)
        }
        let snapshot = await service.status(repoPath: clone)
        #expect(snapshot.upstreamBranch == "origin/main")
        let unpushedShas = Set(
            await service.unpushedCommits(repoPath: clone, hasUpstream: true, limit: 1000)
                .map(\.hash)
        )
        #expect(unpushedShas.count == 3)

        let limit = 3
        // Page 1: the three unpushed local commits, with a cursor onward.
        let raw1 = try #require(
            await service.historyCommits(repoPath: clone, limit: limit + 1, before: nil)
        )
        let page1 = try decodePage(builder.history(
            localCommits: raw1, limit: limit, unpushedShas: unpushedShas, incoming: []
        ))
        #expect(page1.commits.map(\.subject) == ["Local 3", "Local 2", "Local 1"])
        #expect(page1.commits.map(\.isPushed) == [false, false, false])
        let cursor1 = try #require(page1.nextCursor)
        #expect(cursor1 == page1.commits.last?.sha)

        // Page 2: resumes after the cursor with the pushed commits.
        let raw2 = try #require(
            await service.historyCommits(repoPath: clone, limit: limit + 1, before: cursor1)
        )
        let page2 = try decodePage(builder.history(
            localCommits: raw2, limit: limit, unpushedShas: unpushedShas, incoming: []
        ))
        #expect(page2.commits.map(\.subject) == ["Pushed c", "Pushed b", "Pushed a"])
        #expect(page2.commits.map(\.isPushed) == [true, true, true])
        #expect(Set(page1.commits.map(\.sha)).isDisjoint(with: page2.commits.map(\.sha)))
        let cursor2 = try #require(page2.nextCursor)

        // Page 3: the fixture root ends the history — no further cursor.
        let raw3 = try #require(
            await service.historyCommits(repoPath: clone, limit: limit + 1, before: cursor2)
        )
        let page3 = try decodePage(builder.history(
            localCommits: raw3, limit: limit, unpushedShas: unpushedShas, incoming: []
        ))
        #expect(page3.commits.map(\.subject) == ["Initial commit"])
        #expect(page3.commits.map(\.isPushed) == [true])
        #expect(page3.nextCursor == nil)
    }

    @Test func incomingCommitsRideTheFirstPage() async throws {
        let (bare, clone) = try makeRemoteAndClone(prefix: "supermux-history-in")
        defer {
            GitFixture.cleanUp(bare)
            GitFixture.cleanUp(clone)
        }
        // A second clone pushes a commit; the first fetches it (pullable).
        let seeder = try GitFixture.makeTempDirectory(prefix: "supermux-history-seeder")
        defer { GitFixture.cleanUp(seeder) }
        try GitFixture.runGit(["clone", "file://\(bare)", seeder], in: clone)
        try GitFixture.configureIdentity(in: seeder)
        try addCommit("Incoming commit", file: "incoming.txt", in: seeder)
        try GitFixture.runGit(["push"], in: seeder)
        try GitFixture.runGit(["fetch"], in: clone)

        let incoming = await service.incomingCommits(repoPath: clone, limit: 10)
        let raw = try #require(
            await service.historyCommits(repoPath: clone, limit: 11, before: nil)
        )
        let payload = try builder.history(
            localCommits: raw, limit: 10, unpushedShas: [], incoming: incoming
        )
        let page = try decodePage(payload)
        #expect(page.incoming.map(\.subject) == ["Incoming commit"])
        #expect(page.incoming.map(\.isPushed) == [true])
        // The pullable commit is not part of the local page.
        #expect(!page.commits.map(\.subject).contains("Incoming commit"))
    }

    @Test func historyCommitsReturnsNilForAnUnknownCursor() async throws {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-history-cursor")
        defer { GitFixture.cleanUp(repo) }
        let page = await service.historyCommits(
            repoPath: repo, limit: 3, before: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        )
        #expect(page == nil)
    }

    @Test func historyPayloadOmitsNextCursorOnTheLastPage() throws {
        let commits = [
            SupermuxGitCommit(
                hash: "a1", shortHash: "a1", author: "t", relativeDate: "now", subject: "one"
            ),
        ]
        let payload = try builder.history(
            localCommits: commits, limit: 3, unpushedShas: [], incoming: []
        )
        #expect(payload["next_cursor"] == nil)
        #expect((payload["incoming"] as? [Any])?.isEmpty == true)
    }

    // MARK: - Helpers

    private struct Page {
        let commits: [SupermuxCommitDTO]
        let incoming: [SupermuxCommitDTO]
        let nextCursor: String?
    }

    /// Decodes a history payload's DTO arrays through the shared wire bridge.
    private func decodePage(_ payload: [String: Any]) throws -> Page {
        let wire = SupermuxWireJSON()
        let commits = try (payload["commits"] as? [[String: Any]] ?? [])
            .map { try wire.decode(SupermuxCommitDTO.self, from: $0) }
        let incoming = try (payload["incoming"] as? [[String: Any]] ?? [])
            .map { try wire.decode(SupermuxCommitDTO.self, from: $0) }
        return Page(
            commits: commits,
            incoming: incoming,
            nextCursor: payload["next_cursor"] as? String
        )
    }

    /// Writes `file` and commits it with `subject`.
    private func addCommit(_ subject: String, file: String, in repo: String) throws {
        try GitFixture.write("\(subject)\n", to: file, in: repo)
        try GitFixture.runGit(["add", file], in: repo)
        try GitFixture.commit(subject, in: repo)
    }

    /// A bare `file://` remote plus a working clone tracking `origin/main`.
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

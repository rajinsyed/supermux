import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// Core tests for the mobile `changes.history` RPC (validation contract
/// RPC-CHG-06): against a repository with more commits than one page, the
/// pinned-root/offset pagination yields non-overlapping, COMPLETE pages,
/// `next_cursor` resumes exactly where the previous page ended, `is_pushed`
/// flags reflect what is on the `file://` remote, and incoming (pullable)
/// commits ride the first page.
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
        let (page1, cursor1) = try await historyPage(
            in: clone, limit: limit, root: nil, skip: 0, unpushedShas: unpushedShas
        )
        #expect(page1.commits.map(\.subject) == ["Local 3", "Local 2", "Local 1"])
        #expect(page1.commits.map(\.isPushed) == [false, false, false])
        // The compound cursor pins the traversal root (page 1's HEAD) and the
        // offset of the next page — not the last sha.
        let resume1 = try #require(cursor1.flatMap(parseCursor))
        #expect(resume1.skip == limit)
        #expect(resume1.root == page1.commits.first?.sha)

        // Page 2: resumes after the cursor with the pushed commits.
        let (page2, cursor2) = try await historyPage(
            in: clone, limit: limit, root: resume1.root, skip: resume1.skip, unpushedShas: unpushedShas
        )
        #expect(page2.commits.map(\.subject) == ["Pushed c", "Pushed b", "Pushed a"])
        #expect(page2.commits.map(\.isPushed) == [true, true, true])
        #expect(Set(page1.commits.map(\.sha)).isDisjoint(with: page2.commits.map(\.sha)))
        let resume2 = try #require(cursor2.flatMap(parseCursor))

        // Page 3: the fixture root ends the history — no further cursor.
        let (page3, cursor3) = try await historyPage(
            in: clone, limit: limit, root: resume2.root, skip: resume2.skip, unpushedShas: unpushedShas
        )
        #expect(page3.commits.map(\.subject) == ["Initial commit"])
        #expect(page3.commits.map(\.isPushed) == [true])
        #expect(cursor3 == nil)
    }

    /// Regression for the sha-cursor pagination that silently dropped
    /// side-branch commits after page 1: resuming a later page with
    /// `git log <cursor>` only walked that commit's ancestors, so a commit
    /// sorting after the page boundary but reachable through a merge's OTHER
    /// parent never appeared on any page. Pinning the traversal to page 1's
    /// HEAD and advancing by offset returns every commit exactly once.
    @Test func historyPagesDoNotDropSideBranchCommitsAcrossPages() async throws {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-history-merge")
        defer { GitFixture.cleanUp(repo) }
        // A side branch off the root with its own commit...
        try GitFixture.runGit(["checkout", "-b", "feature"], in: repo)
        try addCommit("Feature one", file: "feature-1.txt", in: repo)
        // ...a commit back on the default branch...
        try GitFixture.runGit(["checkout", "-"], in: repo)
        try addCommit("Main two", file: "main-2.txt", in: repo)
        // ...then a real (--no-ff) merge commit tying both parents together.
        try GitFixture.runGit(["merge", "--no-ff", "feature", "-m", "Merge feature"], in: repo)

        // Page size 2 forces the merge's other parent ("Feature one") onto a
        // later page — exactly where the old paging dropped it.
        let limit = 2
        var subjects: [String] = []
        var root: String?
        var skip = 0
        for _ in 0..<10 {
            let (page, cursor) = try await historyPage(
                in: repo, limit: limit, root: root, skip: skip, unpushedShas: []
            )
            subjects.append(contentsOf: page.commits.compactMap(\.subject))
            guard let resume = cursor.flatMap(parseCursor) else { break }
            root = resume.root
            skip = resume.skip
        }
        // No drops, no duplicates: all four commits, "Feature one" included.
        #expect(subjects.count == 4)
        #expect(
            Set(subjects) == ["Merge feature", "Main two", "Feature one", "Initial commit"]
        )
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
            await service.historyCommits(repoPath: clone, limit: 11, from: nil, skip: 0)
        )
        let payload = try builder.history(
            localCommits: raw, limit: 10, unpushedShas: [], incoming: incoming,
            nextCursor: raw.first.map { "\($0.hash).10" } ?? ""
        )
        let page = try decodePage(payload)
        #expect(page.incoming.map(\.subject) == ["Incoming commit"])
        #expect(page.incoming.map(\.isPushed) == [true])
        // The pullable commit is not part of the local page.
        #expect(!page.commits.map(\.subject).contains("Incoming commit"))
    }

    @Test func historyCommitsReturnsNilForAnUnknownRoot() async throws {
        let repo = try GitFixture.makeFixtureRepo(prefix: "supermux-history-cursor")
        defer { GitFixture.cleanUp(repo) }
        let page = await service.historyCommits(
            repoPath: repo, limit: 3,
            from: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", skip: 3
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
            localCommits: commits, limit: 3, unpushedShas: [], incoming: [], nextCursor: "a1.3"
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

    /// Reads one history page through the service + payload builder exactly
    /// as `v2SupermuxChangesHistory` does: pin the traversal root (page 1's
    /// HEAD once known) and emit a compound `<root-sha>.<offset>` cursor.
    private func historyPage(
        in repo: String, limit: Int, root: String?, skip: Int, unpushedShas: Set<String>
    ) async throws -> (page: Page, nextCursor: String?) {
        let raw = try #require(
            await service.historyCommits(repoPath: repo, limit: limit + 1, from: root, skip: skip)
        )
        let startSha = root ?? raw.first?.hash
        let nextCursor = startSha.map { "\($0).\(skip + limit)" } ?? ""
        let payload = try builder.history(
            localCommits: raw, limit: limit, unpushedShas: unpushedShas,
            incoming: [], nextCursor: nextCursor
        )
        return (try decodePage(payload), payload["next_cursor"] as? String)
    }

    /// Parses the handler's compound `<root-sha>.<offset>` cursor.
    private func parseCursor(_ cursor: String) -> (root: String, skip: Int)? {
        let parts = cursor.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let skip = Int(parts[1]) else { return nil }
        return (String(parts[0]), skip)
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

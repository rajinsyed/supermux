import Foundation
import Testing

import SupermuxKit

/// A new worktree starts from the base branch as it is on `origin`, not from a
/// stale local copy. Ways this could fail:
///
/// 1. Local `main` is behind `origin/main` (someone pushed since the last
///    fetch), and the worktree starts from the old local commit, so the agent
///    works on stale code. Both an unset base (which prefers `main`) and an
///    explicit `main` base must start from the remote commit.
/// 2. Local `main` has unpushed commits, and branching from `origin/main`
///    silently drops them.
/// 3. Local `main` and `origin/main` have diverged, and either side's commits
///    are picked without the local ones.
/// 4. A base branch that was pushed after the last fetch is reported as
///    unknown instead of being found on `origin`.
/// 5. `origin` is unreachable (offline, deleted, auth), and creation fails or
///    hangs instead of starting from the local branch.
/// 6. Starting from `origin/main` records `origin/main` (not `main`) as the
///    worktree's base, or makes the new branch track `origin/main`.
/// 7. Refreshing the base moves the user's local `main`, which can be checked
///    out in the main checkout.
/// 8. The start point is passed to git as a short name, so a local branch
///    named `origin/main` or a tag named `main` makes it ambiguous and git
///    refuses to create the worktree.
@Suite(.serialized) struct SupermuxGitWorktreeFreshBaseTests {
    private let service = SupermuxGitWorktreeService()

    /// A fixture repository with an `origin` remote (a bare clone), fetched
    /// once so `origin/main` exists like in a real clone.
    private struct OriginFixture {
        var root: String
        var origin: String
        var project: SupermuxProject

        func cleanUp() {
            GitFixture.cleanUp(root)
            GitFixture.cleanUp(origin)
        }
    }

    private func makeOriginFixture() throws -> OriginFixture {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-fresh-base-tests")
        let origin = try GitFixture.makeTempDirectory(prefix: "supermux-fresh-base-origin")
        try GitFixture.runGit(["clone", "--quiet", "--bare", root, origin], in: origin)
        try GitFixture.runGit(["remote", "add", "origin", origin], in: root)
        try GitFixture.runGit(["fetch", "--quiet", "origin"], in: root)
        return OriginFixture(
            root: root,
            origin: origin,
            project: SupermuxProject(name: "Fixture", rootPath: root)
        )
    }

    /// Pushes a new commit on `branch` to `origin` from a separate clone, the
    /// way a teammate (or another worktree) would, and returns its SHA. The
    /// fixture repository does not see it until it fetches.
    @discardableResult
    private func pushFromAnotherClone(to origin: String, branch: String, file: String) throws -> String {
        let clone = try GitFixture.makeTempDirectory(prefix: "supermux-fresh-base-teammate")
        defer { GitFixture.cleanUp(clone) }
        try GitFixture.runGit(["clone", "--quiet", origin, clone], in: clone)
        try GitFixture.configureIdentity(in: clone)
        try GitFixture.runGit(["switch", "--quiet", "-C", branch], in: clone)
        try GitFixture.write("\(file)\n", to: file, in: clone)
        try GitFixture.runGit(["add", file], in: clone)
        try GitFixture.commit("Add \(file)", in: clone)
        try GitFixture.runGit(["push", "--quiet", "origin", branch], in: clone)
        return try head(of: "HEAD", in: clone)
    }

    /// Commits `file` on the fixture's current branch without pushing it.
    @discardableResult
    private func commitLocally(_ file: String, in root: String) throws -> String {
        try GitFixture.write("\(file)\n", to: file, in: root)
        try GitFixture.runGit(["add", file], in: root)
        try GitFixture.commit("Add \(file)", in: root)
        return try head(of: "HEAD", in: root)
    }

    private func head(of ref: String, in directory: String) throws -> String {
        try GitFixture.runGit(["rev-parse", ref], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tests

    @Test(arguments: [nil, "main"] as [String?])
    func startsFromOriginWhenLocalBaseIsBehind(baseBranch: String?) async throws {
        let fixture = try makeOriginFixture()
        defer { fixture.cleanUp() }
        let localMain = try head(of: "main", in: fixture.root)
        let pushed = try pushFromAnotherClone(to: fixture.origin, branch: "main", file: "PUSHED.md")

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature",
            baseBranch: baseBranch
        )

        #expect(try head(of: "HEAD", in: worktree.path) == pushed)
        // The user's local main is left alone.
        #expect(try head(of: "main", in: fixture.root) == localMain)
        // The base is recorded by name, and the new branch tracks nothing.
        let recordedBase = try GitFixture.runGit(["config", "branch.feature.base"], in: fixture.root)
        #expect(recordedBase.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
        #expect((try? GitFixture.runGit(["config", "branch.feature.merge"], in: fixture.root)) == nil)
    }

    @Test func keepsLocalBaseWithUnpushedCommits() async throws {
        let fixture = try makeOriginFixture()
        defer { fixture.cleanUp() }
        let unpushed = try commitLocally("UNPUSHED.md", in: fixture.root)

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature",
            baseBranch: "main"
        )

        #expect(try head(of: "HEAD", in: worktree.path) == unpushed)
    }

    @Test func keepsLocalBaseWhenDivergedFromOrigin() async throws {
        let fixture = try makeOriginFixture()
        defer { fixture.cleanUp() }
        try pushFromAnotherClone(to: fixture.origin, branch: "main", file: "PUSHED.md")
        let unpushed = try commitLocally("UNPUSHED.md", in: fixture.root)

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature",
            baseBranch: "main"
        )

        #expect(try head(of: "HEAD", in: worktree.path) == unpushed)
    }

    @Test func findsBaseBranchPushedSinceLastFetch() async throws {
        let fixture = try makeOriginFixture()
        defer { fixture.cleanUp() }
        let pushed = try pushFromAnotherClone(to: fixture.origin, branch: "release", file: "RELEASE.md")

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "hotfix",
            baseBranch: "release"
        )

        #expect(try head(of: "HEAD", in: worktree.path) == pushed)
        let recordedBase = try GitFixture.runGit(["config", "branch.hotfix.base"], in: fixture.root)
        #expect(recordedBase.trimmingCharacters(in: .whitespacesAndNewlines) == "release")
    }

    @Test func startsFromLocalBaseWhenOriginIsUnreachable() async throws {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-fresh-base-tests")
        defer { GitFixture.cleanUp(root) }
        let missing = (root as NSString).appendingPathComponent("no-such-origin.git")
        try GitFixture.runGit(["remote", "add", "origin", missing], in: root)
        let localMain = try head(of: "main", in: root)

        let worktree = try await service.createWorktree(
            project: SupermuxProject(name: "Fixture", rootPath: root),
            requestedBranch: "feature",
            baseBranch: "main"
        )

        #expect(try head(of: "HEAD", in: worktree.path) == localMain)
    }

    @Test func startsFromOriginWhenALocalBranchShadowsItsName() async throws {
        let fixture = try makeOriginFixture()
        defer { fixture.cleanUp() }
        try GitFixture.runGit(["branch", "origin/main"], in: fixture.root)
        let pushed = try pushFromAnotherClone(to: fixture.origin, branch: "main", file: "PUSHED.md")

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature",
            baseBranch: "main"
        )

        #expect(try head(of: "HEAD", in: worktree.path) == pushed)
    }

    @Test func startsFromTheBranchWhenATagSharesItsName() async throws {
        let fixture = try makeOriginFixture()
        defer { fixture.cleanUp() }
        try GitFixture.runGit(["tag", "main"], in: fixture.root)
        let unpushed = try commitLocally("UNPUSHED.md", in: fixture.root)

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature",
            baseBranch: "main"
        )

        #expect(try head(of: "HEAD", in: worktree.path) == unpushed)
    }
}

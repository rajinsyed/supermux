import CmuxFoundation
import Foundation
import Testing

import SupermuxKit

/// Integration tests for `SupermuxGitWorktreeService` against real temporary
/// git repositories. Every test builds its own fixture repository so the
/// suite stays parallel-safe, and removes it on exit.
// Serialized: these tests shell out to real `git`. Run alongside the other
// git-integration suites they spawned enough concurrent subprocesses to flake
// (a fixture's `git init` intermittently read back as "not a git repository").
// Serializing keeps peak git-subprocess concurrency low without slowing CI
// meaningfully.
@Suite(.serialized) struct SupermuxGitWorktreeServiceTests {
    private let service = SupermuxGitWorktreeService()

    // MARK: - Fixture helpers (shared implementation in `GitFixture`)

    /// A throwaway git repository plus the project record pointing at it.
    private struct Fixture {
        var root: String
        var project: SupermuxProject
    }

    /// A fixture repository that carries an initialized git submodule, plus the
    /// standalone repo serving as the submodule's source.
    private struct SubmoduleFixture {
        var root: String
        var submoduleSource: String
        var project: SupermuxProject
    }

    /// This suite's temp-directory prefix, kept distinct per file so parallel
    /// test runs stay distinguishable.
    private func makeTempDirectory() throws -> String {
        try GitFixture.makeTempDirectory(prefix: "supermux-worktree-tests")
    }

    /// Creates a temp git repository on `main` with one commit, plus a
    /// `SupermuxProject` pointing at it.
    private func makeFixtureRepo() throws -> Fixture {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-worktree-tests")
        return Fixture(root: root, project: SupermuxProject(name: "Fixture", rootPath: root))
    }

    /// Creates a fixture repo whose tree contains one committed submodule
    /// (`vendored`). The submodule is added but not yet checked out in any
    /// worktree; tests initialize it where they need git to see a live submodule.
    /// `protocol.file.allow=always` is required because the submodule source is a
    /// local path (git blocks the `file://` transport for submodules by default).
    private func makeFixtureRepoWithSubmodule() throws -> SubmoduleFixture {
        // A standalone repo to serve as the submodule's source.
        let submoduleSource = try makeTempDirectory()
        try GitFixture.runGit(["init", "-b", "main"], in: submoduleSource)
        try GitFixture.configureIdentity(in: submoduleSource)
        try GitFixture.write("library\n", to: "LIB.md", in: submoduleSource)
        try GitFixture.runGit(["add", "."], in: submoduleSource)
        try GitFixture.commit("Submodule init", in: submoduleSource)

        // The main fixture repo, with the source wired in as a submodule.
        let fixture = try makeFixtureRepo()
        try GitFixture.runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", submoduleSource, "vendored"],
            in: fixture.root
        )
        try GitFixture.commit("Add submodule", in: fixture.root)
        return SubmoduleFixture(
            root: fixture.root,
            submoduleSource: submoduleSource,
            project: fixture.project
        )
    }

    // MARK: - Repository probes

    @Test func isGitRepositoryDetectsReposAndPlainDirectories() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let emptyDir = try makeTempDirectory()
        defer { GitFixture.cleanUp(emptyDir) }

        #expect(await service.isGitRepository(at: fixture.root))
        #expect(await service.isGitRepository(at: emptyDir) == false)
    }

    @Test func currentBranchReturnsMain() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }

        #expect(await service.currentBranch(repoRoot: fixture.root) == "main")
    }

    // MARK: - Worktree creation

    @Test func createWorktreeSanitizesBranchAndConfiguresCheckout() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "my feature"
        )

        #expect(worktree.branch == "my-feature")
        let expectedPath = (fixture.root as NSString)
            .appendingPathComponent(".worktrees/my-feature")
        #expect(worktree.path == expectedPath)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expectedPath, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)

        let listed = try await service.listWorktrees(for: fixture.project)
        let entry = try #require(listed.first { $0.path == expectedPath })
        #expect(entry.branch == "my-feature")
        #expect(entry.isSupermuxManaged)

        let excludePath = (fixture.root as NSString).appendingPathComponent(".git/info/exclude")
        let exclude = try String(contentsOfFile: excludePath, encoding: .utf8)
        #expect(exclude.contains("/.worktrees/"))

        let autoSetupRemote = try GitFixture.runGit(
            ["-C", worktree.path, "config", "--local", "push.autoSetupRemote"],
            in: fixture.root
        )
        #expect(autoSetupRemote.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }

    @Test func createWorktreeGeneratesFriendlyNameWhenBranchBlank() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }

        // A blank branch field must not error — it generates a friendly,
        // git-safe two-word branch and a real worktree on disk.
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "   "
        )

        let branch = try #require(worktree.branch)
        let parts = branch.split(separator: "-", omittingEmptySubsequences: false)
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { !$0.isEmpty })
        #expect(SupermuxBranchName().sanitize(branch) == branch)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
        #expect(worktree.isSupermuxManaged)
    }

    @Test func createWorktreeDeduplicatesBranchNames() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }

        let first = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "my feature"
        )
        let second = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "my feature"
        )

        #expect(first.branch == "my-feature")
        #expect(second.branch == "my-feature-2")
    }

    @Test func createWorktreeAvoidsDirectoryCollisionBetweenSlashAndDashBranches() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let first = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature-foo"
        )
        #expect(first.branch == "feature-foo")

        // "feature/foo" is a free branch name but flattens to the directory
        // "feature-foo" already in use; creation must dedup to a free
        // directory instead of failing on git's "'<path>' already exists".
        let second = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature/foo"
        )
        #expect(second.branch == "feature/foo-2")
        #expect((second.path as NSString).lastPathComponent == "feature-foo-2")
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func createWorktreeAvoidsRegisteredButDeletedWorktreeDirectory() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let original = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "alpha"
        )
        // Free the branch name but keep the worktree registration, then delete
        // the directory: `git worktree add` at the same path would fail with
        // "missing but already registered worktree".
        try GitFixture.runGit(["branch", "-m", "alpha", "beta"], in: fixture.root)
        try FileManager.default.removeItem(atPath: original.path)

        let recreated = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "alpha"
        )
        #expect(recreated.branch == "alpha-2")
        #expect(FileManager.default.fileExists(atPath: recreated.path))
    }

    @Test func createWorktreeRetriesWhenDedupedBranchRacesIntoExistence() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        // The actor is reentrant: a concurrent creation can claim the deduped
        // name between the branch snapshot and the add. The injecting runner
        // simulates exactly that; the service must retry with a fresh dedup
        // instead of surfacing "a branch named 'feature' already exists".
        let racing = SupermuxGitWorktreeService(runner: BranchRaceInjectingRunner())

        let worktree = try await racing.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )

        #expect(worktree.branch == "feature-2")
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func timedOutWorktreeAddGetsCheckoutDeadlineAndCleansUp() async throws {
        let root = try makeTempDirectory()
        defer { GitFixture.cleanUp(root) }
        let runner = TimedOutAddRunner()
        let scripted = SupermuxGitWorktreeService(runner: runner)
        let project = SupermuxProject(name: "Slow", rootPath: root)

        do {
            _ = try await scripted.createWorktree(project: project, requestedBranch: "feature")
            Issue.record("Expected the timed-out add to throw")
        } catch let error as SupermuxGitError {
            #expect(error == .gitFailed(command: "worktree add", message: "timed out"))
        }

        // `worktree add` checks out a full tree (LFS smudge included) and must
        // get a checkout-weight deadline, not the blanket 30s git timeout.
        let add = try #require(await runner.first(withPrefix: ["worktree", "add"]))
        #expect((add.timeout ?? 0) >= 600)
        // Best-effort cleanup so a same-name retry succeeds: force-remove the
        // partial checkout, prune the admin entry, delete the orphan branch.
        #expect(await runner.first(withPrefix: ["worktree", "remove", "--force"]) != nil)
        #expect(await runner.first(withPrefix: ["worktree", "prune"]) != nil)
        #expect(await runner.first(withPrefix: ["branch", "-D", "feature"]) != nil)
    }

    @Test func worktreeCreatedThroughSymlinkedProjectRootStaysManaged() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let linkParent = try makeTempDirectory()
        defer { GitFixture.cleanUp(linkParent) }
        let linkPath = (linkParent as NSString).appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: fixture.root)
        // `git worktree list` prints symlink-resolved paths, so a project
        // registered via a symlinked root must still match its own worktrees.
        let project = SupermuxProject(name: "Linked", rootPath: linkPath)

        let worktree = try await service.createWorktree(project: project, requestedBranch: "feature")
        #expect(worktree.isSupermuxManaged)

        let listed = try await service.listWorktrees(for: project)
        // No bogus extra row for the primary checkout, and the created
        // worktree still resolves as supermux-managed.
        #expect(listed.count == 1)
        let entry = try #require(listed.first)
        #expect(entry.branch == "feature")
        #expect(entry.isSupermuxManaged)

        try await service.removeWorktree(entry, project: project)
        #expect(FileManager.default.fileExists(atPath: entry.path) == false)
    }

    @Test func createWorktreeAllowsSymlinkedWorktreesContainer() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let external = try makeTempDirectory()
        defer { GitFixture.cleanUp(external) }
        // Keeping checkouts on "another volume": <root>/.worktrees is a symlink
        // pointing outside the repo root — a legitimate setup the (lexical)
        // `..`-escape guard must not reject even though the container's
        // canonical form escapes the root.
        try FileManager.default.createSymbolicLink(
            atPath: (fixture.root as NSString).appendingPathComponent(".worktrees"),
            withDestinationPath: external
        )

        let worktree = try await service.createWorktree(
            project: fixture.project, requestedBranch: "feature"
        )

        #expect(worktree.branch == "feature")
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        // The checkout physically lives in the symlink's target… (the target
        // exists, so a plain symlink resolve yields the canonical form)
        #expect(worktree.path.hasPrefix((external as NSString).resolvingSymlinksInPath + "/"))
        // …and still round-trips as supermux-managed through `git worktree list`.
        let listed = try await service.listWorktrees(for: fixture.project)
        let entry = try #require(listed.first { $0.branch == "feature" })
        #expect(entry.isSupermuxManaged)
    }

    @Test func failingAddAfterBranchCreationSurfacesWithoutRetryJunk() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        // A post-checkout hook that always fails: `git worktree add` creates
        // the branch AND registers the worktree, then exits non-zero. A bare
        // ref-exists retry gate would blame the reentrancy race and silently
        // pile `feature-2` junk next to the half-created worktree.
        let hooksDir = (fixture.root as NSString).appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        let hookPath = (hooksDir as NSString).appendingPathComponent("post-checkout")
        try "#!/bin/sh\nexit 1\n".write(toFile: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

        do {
            _ = try await service.createWorktree(project: fixture.project, requestedBranch: "feature")
            Issue.record("Expected the failing post-checkout hook to surface")
        } catch let error as SupermuxGitError {
            guard case .gitFailed = error else {
                Issue.record("Expected .gitFailed, got \(error)")
                return
            }
        }

        // Exactly one attempt: no silently-created `feature-2` branch.
        let branches = try GitFixture.runGit(["branch", "--list", "--format=%(refname:short)"], in: fixture.root)
            .split(separator: "\n").map(String.init)
        #expect(branches.contains("feature"))
        #expect(!branches.contains("feature-2"))
    }

    @Test func createWorktreeRecordsBaseBranch() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }

        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature",
            baseBranch: "main"
        )

        let branch = try #require(worktree.branch)
        let recordedBase = try GitFixture.runGit(["config", "branch.\(branch).base"], in: fixture.root)
        #expect(recordedBase.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }

    // MARK: - Worktree removal

    @Test func removeWorktreeRemovesCleanCheckout() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )

        try await service.removeWorktree(worktree, project: fixture.project)

        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    }

    @Test func removeWorktreeSucceedsWhenCheckoutDirectoryDeletedExternally() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )
        // Deleted in Finder/terminal: git keeps the registration, so the entry
        // still lists — and must stay recognizably supermux-managed.
        try FileManager.default.removeItem(atPath: worktree.path)
        let listed = try await service.listWorktrees(for: fixture.project)
        let stale = try #require(listed.first { $0.branch == "feature" })
        #expect(stale.isSupermuxManaged)

        // A deleted checkout has no uncommitted work to lose: non-force
        // removal must succeed instead of misreporting "uncommitted changes".
        try await service.removeWorktree(stale, project: fixture.project)

        let after = try await service.listWorktrees(for: fixture.project)
        #expect(after.contains { $0.branch == "feature" } == false)
    }

    @Test func removeWorktreeRefusesDirtyCheckoutUnlessForced() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )
        let untrackedPath = (worktree.path as NSString).appendingPathComponent("scratch.txt")
        try "uncommitted\n".write(toFile: untrackedPath, atomically: true, encoding: .utf8)

        await #expect(throws: SupermuxGitError.dirtyWorktree(path: worktree.path)) {
            try await service.removeWorktree(worktree, project: fixture.project)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try await service.removeWorktree(worktree, project: fixture.project, force: true)
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    }

    @Test func removeWorktreeWithInitializedSubmodule() async throws {
        let fixture = try makeFixtureRepoWithSubmodule()
        defer { GitFixture.cleanUp(fixture.root) }
        defer { GitFixture.cleanUp(fixture.submoduleSource) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )
        // Check the submodule out inside the worktree so git's
        // `validate_no_submodules` makes a plain `git worktree remove` abort with
        // "working trees containing submodules cannot be moved or removed". This
        // is the exact state of a real worktree of a submodule-bearing repo.
        try GitFixture.runGit(
            ["-c", "protocol.file.allow=always", "-C", worktree.path, "submodule", "update", "--init"],
            in: fixture.root
        )
        let submodulePath = (worktree.path as NSString).appendingPathComponent("vendored/LIB.md")
        #expect(FileManager.default.fileExists(atPath: submodulePath))

        // Removal must still succeed: it force-removes, which git allows for a
        // submodule-bearing worktree (and cleans up the admin entry itself).
        try await service.removeWorktree(worktree, project: fixture.project)

        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
        // git's own --force removal drops the admin entry, so the worktree no longer lists.
        let listed = try await service.listWorktrees(for: fixture.project)
        #expect(listed.contains { $0.path == worktree.path } == false)
    }

    @Test func removeWorktreeRefusesDirtySubmoduleUnlessForced() async throws {
        let fixture = try makeFixtureRepoWithSubmodule()
        defer { GitFixture.cleanUp(fixture.root) }
        defer { GitFixture.cleanUp(fixture.submoduleSource) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )
        try GitFixture.runGit(
            ["-c", "protocol.file.allow=always", "-C", worktree.path, "submodule", "update", "--init"],
            in: fixture.root
        )
        // Uncommitted work *inside* the submodule must count as dirty. Removal now
        // always force-removes (which waives git's own checks), so the porcelain
        // `--ignore-submodules=none` guard is the only thing standing between a
        // non-force delete and silently lost submodule work.
        let trackedInSubmodule = (worktree.path as NSString).appendingPathComponent("vendored/LIB.md")
        try "local edit\n".write(toFile: trackedInSubmodule, atomically: true, encoding: .utf8)

        await #expect(throws: SupermuxGitError.dirtyWorktree(path: worktree.path)) {
            try await service.removeWorktree(worktree, project: fixture.project)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        // Forcing past the guard still removes it, dirty submodule and all.
        try await service.removeWorktree(worktree, project: fixture.project, force: true)
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    }

    @Test func removeWorktreeCanDeleteBranch() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let worktree = try await service.createWorktree(
            project: fixture.project,
            requestedBranch: "feature"
        )
        let branch = try #require(worktree.branch)

        try await service.removeWorktree(worktree, project: fixture.project, deleteBranch: true)

        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
        let listing = try GitFixture.runGit(["branch", "--list", branch], in: fixture.root)
        #expect(listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func removeWorktreeRunsTeardownScriptWithEnvironment() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        var project = fixture.project
        // Teardown writes the exported worktree path into the main checkout, so
        // we can assert it ran, with the environment set, before removal.
        project.teardownCommands = [
            #"printf '%s' "$SUPERMUX_WORKTREE_PATH" > "$SUPERSET_ROOT_PATH/teardown-marker""#
        ]
        let worktree = try await service.createWorktree(project: project, requestedBranch: "feature")

        try await service.removeWorktree(worktree, project: project)

        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
        let markerPath = (fixture.root as NSString).appendingPathComponent("teardown-marker")
        let marker = try String(contentsOfFile: markerPath, encoding: .utf8)
        #expect(marker == worktree.path)
    }

    @Test func teardownThatDirtiesTheWorktreeStillRemoves() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        var project = fixture.project
        // Teardown drops an untracked file into the worktree, dirtying a checkout
        // we already verified clean. The (non-force) removal must still succeed —
        // teardown's own side effects must not block the deletion it precedes.
        project.teardownCommands = [#"touch "$SUPERMUX_WORKTREE_PATH/teardown-scratch.txt""#]
        let worktree = try await service.createWorktree(project: project, requestedBranch: "feature")

        try await service.removeWorktree(worktree, project: project)
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    }

    @Test func failingTeardownDoesNotBlockRemoval() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        var project = fixture.project
        project.teardownCommands = ["exit 7"]
        let worktree = try await service.createWorktree(project: project, requestedBranch: "feature")

        // A non-zero teardown exit is best-effort: it must neither throw nor
        // leave the worktree behind.
        try await service.removeWorktree(worktree, project: project)
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    }

    @Test func removeWorktreeRefusesUnmanagedWorktrees() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }
        let sibling = try makeTempDirectory()
        defer { GitFixture.cleanUp(sibling) }
        let outsidePath = (sibling as NSString).appendingPathComponent("manual-worktree")
        try GitFixture.runGit(["worktree", "add", "-b", "manual-branch", outsidePath], in: fixture.root)

        let listed = try await service.listWorktrees(for: fixture.project)
        let manual = try #require(listed.first { $0.branch == "manual-branch" })
        #expect(manual.isSupermuxManaged == false)

        await #expect(throws: SupermuxGitError.unmanagedWorktree(path: manual.path)) {
            try await service.removeWorktree(manual, project: fixture.project)
        }
    }

    // MARK: - Path-escape regressions

    /// A project whose `worktreesDirName` is `".."` resolves its worktrees
    /// container to the *parent* of the repository. `createWorktree` must refuse
    /// with ``SupermuxGitError/unsafeWorktreePath(path:)`` and must not create any
    /// directory in that parent.
    @Test func createWorktreeRejectsEscapingWorktreesDir() async throws {
        // Nest the repo inside a controlled parent we own so we can assert on the
        // parent's contents without racing the shared system temp directory.
        let parent = try makeTempDirectory()
        defer { GitFixture.cleanUp(parent) }
        let root = (parent as NSString).appendingPathComponent("repo")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try GitFixture.runGit(["init", "-b", "main"], in: root)
        try GitFixture.configureIdentity(in: root)
        try GitFixture.write("fixture\n", to: "README.md", in: root)
        try GitFixture.runGit(["add", "."], in: root)
        try GitFixture.commit("Initial commit", in: root)

        let escaped = SupermuxProject(
            name: "Escaped",
            rootPath: root,
            worktreesDirName: ".."
        )

        await #expect(throws: SupermuxGitError.self) {
            try await service.createWorktree(project: escaped, requestedBranch: "escape")
        }

        // And specifically the unsafe-path case (not, say, a generic git failure).
        do {
            _ = try await service.createWorktree(project: escaped, requestedBranch: "escape")
            Issue.record("Expected createWorktree to throw for an escaping worktrees dir")
        } catch let error as SupermuxGitError {
            guard case .unsafeWorktreePath = error else {
                Issue.record("Expected .unsafeWorktreePath, got \(error)")
                return
            }
        }

        // Nothing escaped into the parent: only the repo itself remains, and no
        // "escape" worktree directory was created next to it.
        let parentEntries = Set((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
        #expect(parentEntries == ["repo"])
        #expect(parentEntries.contains("escape") == false)
        #expect(FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent("escape")) == false)
    }

    /// A worktree living *outside* the project root must never be flagged as
    /// supermux-managed for a project whose `worktreesDirName` escaped the root.
    /// With the corrupt `".."` config the managed prefix resolves to the parent
    /// directory, so a worktree placed directly under that parent (a sibling of
    /// the repo) would be mis-flagged managed and offered up for deletion. The
    /// service must fall back to a match-nothing sentinel instead.
    @Test func listWorktreesNeverFlagsSiblingsManagedForEscapingConfig() async throws {
        let fixture = try makeFixtureRepo()
        defer { GitFixture.cleanUp(fixture.root) }

        // A second, independent git repo living as a sibling of the fixture,
        // with its own real worktree (also a sibling of the fixture). It must
        // never be reported as supermux-managed.
        let parent = (fixture.root as NSString).deletingLastPathComponent
        let siblingRoot = (parent as NSString)
            .appendingPathComponent("supermux-sibling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: siblingRoot, withIntermediateDirectories: true)
        defer { GitFixture.cleanUp(siblingRoot) }
        try GitFixture.runGit(["init", "-b", "main"], in: siblingRoot)
        try GitFixture.configureIdentity(in: siblingRoot)
        try GitFixture.write("sibling\n", to: "README.md", in: siblingRoot)
        try GitFixture.runGit(["add", "."], in: siblingRoot)
        try GitFixture.commit("Sibling commit", in: siblingRoot)
        let siblingWorktree = (parent as NSString)
            .appendingPathComponent("supermux-sibling-wt-\(UUID().uuidString)")
        defer { GitFixture.cleanUp(siblingWorktree) }
        try GitFixture.runGit(["worktree", "add", "-b", "sibling-branch", siblingWorktree], in: siblingRoot)

        // `git worktree list` in the fixture repo only enumerates the fixture's
        // own worktrees, so to exercise the managed-flagging path we give the
        // fixture a worktree that lives directly under the parent — i.e. inside
        // the directory the escaped `".."` config resolves the managed prefix
        // to. Under the bug this fixture-owned sibling would be flagged managed.
        let escapingWorktree = (parent as NSString)
            .appendingPathComponent("supermux-escaped-wt-\(UUID().uuidString)")
        defer { GitFixture.cleanUp(escapingWorktree) }
        try GitFixture.runGit(["worktree", "add", "-b", "escaped-branch", escapingWorktree], in: fixture.root)

        // The fixture project, but mis-configured to escape into the parent.
        let escaped = SupermuxProject(
            name: "Escaped",
            rootPath: fixture.root,
            worktreesDirName: ".."
        )

        // With the escaped config NO listed worktree may be flagged managed: a
        // corrupt prefix must fall back to a sentinel that matches nothing so no
        // sibling worktree is ever reported deletable.
        let listed = try await service.listWorktrees(for: escaped)
        #expect(listed.isEmpty == false)
        for worktree in listed {
            #expect(worktree.isSupermuxManaged == false)
        }
        // The fixture-owned worktree under the parent specifically must be unmanaged.
        let normalizedEscaping = (escapingWorktree as NSString).standardizingPath
        let escapedEntry = try #require(listed.first { $0.path == normalizedEscaping })
        #expect(escapedEntry.isSupermuxManaged == false)
        // And if the sibling repo's worktree ever surfaced here, it must not be managed.
        let normalizedSibling = (siblingWorktree as NSString).standardizingPath
        if let sibling = listed.first(where: { $0.path == normalizedSibling }) {
            #expect(sibling.isSupermuxManaged == false)
        }
    }

    /// Documents *why* the service guard is needed: `worktreesDirName == ".."`
    /// makes the worktrees container resolve to the project's parent directory.
    /// No git involved — a plain value assertion about path resolution.
    @Test func worktreesDirPathWithDotDotResolvesToParent() {
        let root = "/Users/example/projects/repo"
        let project = SupermuxProject(name: "Repo", rootPath: root, worktreesDirName: "..")

        // The raw path appends ".." literally; standardizing collapses it to the parent.
        let resolved = (project.worktreesDirPath as NSString).standardizingPath
        let parent = (root as NSString).deletingLastPathComponent
        #expect(resolved == parent)
        // The resolved container is NOT inside the root — exactly the unsafe case
        // the service rejects with `.unsafeWorktreePath`.
        #expect(resolved.hasPrefix(root + "/") == false)
    }
}

// The `/usr/bin/env VAR=… git` unwrapping these fakes rely on lives in
// `SupermuxGitTestSupport.swift` (`unwrappedGitArguments`), shared with the
// changes-service fakes.

/// Delegates to the real `CommandRunner`, but creates the branch the first
/// `worktree add` is about to claim just before running it — simulating a
/// concurrent creation racing through the reentrant actor.
private actor BranchRaceInjectingRunner: CommandRunning {
    private let wrapped = CommandRunner()
    private var injected = false

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let gitArguments = unwrappedGitArguments(executable: executable, arguments: arguments)
        if !injected, gitArguments.count > 4, gitArguments[0] == "worktree", gitArguments[1] == "add" {
            injected = true
            _ = await wrapped.run(
                directory: directory,
                executable: "git",
                arguments: ["branch", gitArguments[4]],
                timeout: timeout
            )
        }
        return await wrapped.run(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }
}

/// Scripted runner whose `worktree add` always times out; everything else
/// reports success. Records every invocation so tests can assert on the
/// deadlines and cleanup commands the service issues.
private actor TimedOutAddRunner: CommandRunning {
    struct Invocation: Sendable {
        var arguments: [String]
        var timeout: TimeInterval?
    }

    private(set) var invocations: [Invocation] = []

    func first(withPrefix prefix: [String]) -> Invocation? {
        invocations.first { $0.arguments.starts(with: prefix) }
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        // Record the plain git argv (env wrapper stripped) so assertions match
        // the service's logical git invocations regardless of routing.
        let gitArguments = unwrappedGitArguments(executable: executable, arguments: arguments)
        invocations.append(Invocation(arguments: gitArguments, timeout: timeout))
        if gitArguments.starts(with: ["worktree", "add"]) {
            return CommandResult(stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil)
        }
        let stdout: String
        switch gitArguments.first {
        case "rev-parse":
            stdout = gitArguments.contains("--is-inside-work-tree") ? "true\n" : ".git\n"
        default:
            stdout = ""
        }
        return CommandResult(stdout: stdout, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
    }
}

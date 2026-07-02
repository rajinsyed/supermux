import Foundation
import SupermuxKit
import Testing

struct SupermuxProjectMatcherTests {
    private let matcher = SupermuxProjectMatcher()

    private func project(name: String, root: String) -> SupermuxProject {
        SupermuxProject(name: name, rootPath: root)
    }

    @Test func matchesExactRoot() {
        let p = project(name: "a", root: "/repos/a")
        #expect(matcher.project(for: "/repos/a", in: [p])?.id == p.id)
    }

    @Test func matchesSubdirectoryOfRoot() {
        let p = project(name: "a", root: "/repos/a")
        #expect(matcher.project(for: "/repos/a/src/deep", in: [p])?.id == p.id)
    }

    @Test func matchesWorktreeCheckout() {
        let p = project(name: "a", root: "/repos/a")
        #expect(matcher.project(for: "/repos/a/.worktrees/my-branch", in: [p])?.id == p.id)
    }

    @Test func rejectsSiblingWithSharedPrefix() {
        let p = project(name: "a", root: "/repos/a")
        #expect(matcher.project(for: "/repos/a-sibling", in: [p]) == nil)
    }

    @Test func mostSpecificRootWins() {
        let outer = project(name: "outer", root: "/repos/mono")
        let inner = project(name: "inner", root: "/repos/mono/packages/inner")
        let result = matcher.project(for: "/repos/mono/packages/inner/src", in: [outer, inner])
        #expect(result?.id == inner.id)
    }

    @Test func nilAndEmptyDirectoriesMatchNothing() {
        let p = project(name: "a", root: "/repos/a")
        #expect(matcher.project(for: nil, in: [p]) == nil)
        #expect(matcher.project(for: "", in: [p]) == nil)
    }

    @Test func normalizesTrailingSlashes() {
        let p = project(name: "a", root: "/repos/a/")
        #expect(matcher.project(for: "/repos/a", in: [p])?.id == p.id)
    }

    // MARK: - projectOwningWorktree (nesting signal: worktrees dir only)

    @Test func worktreeMatchMatchesWorktreeCheckout() {
        let p = project(name: "a", root: "/repos/a")
        #expect(matcher.projectOwningWorktree(for: "/repos/a/.worktrees/my-branch", in: [p])?.id == p.id)
    }

    @Test func worktreeMatchIgnoresRootAndSubdirectories() {
        let p = project(name: "a", root: "/repos/a")
        // The project root and arbitrary subdirectories must NOT nest as worktrees —
        // this is what keeps a standalone workspace that inherited a project
        // directory out of the project's nested list.
        #expect(matcher.projectOwningWorktree(for: "/repos/a", in: [p]) == nil)
        #expect(matcher.projectOwningWorktree(for: "/repos/a/src/deep", in: [p]) == nil)
    }

    @Test func worktreeMatchIgnoresBareWorktreesContainer() {
        let p = project(name: "a", root: "/repos/a")
        #expect(matcher.projectOwningWorktree(for: "/repos/a/.worktrees", in: [p]) == nil)
    }

    @Test func worktreeMatchNilAndEmptyMatchNothing() {
        let p = project(name: "a", root: "/repos/a")
        #expect(matcher.projectOwningWorktree(for: nil, in: [p]) == nil)
        #expect(matcher.projectOwningWorktree(for: "", in: [p]) == nil)
    }

    // MARK: - Symlinked project roots

    /// Creates `base/physical/repo/.worktrees/feature` on disk plus a
    /// `base/link → base/physical` symlink, so a project registered through
    /// the link has a distinct physical spelling.
    private func makeSymlinkedRepo() throws -> (base: URL, logicalRoot: String, physicalRoot: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("physical/repo/.worktrees/feature"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link"),
            withDestinationURL: base.appendingPathComponent("physical")
        )
        return (
            base,
            base.appendingPathComponent("link/repo").path,
            base.appendingPathComponent("physical/repo").path
        )
    }

    @Test func matchesPhysicalPathForProjectRegisteredThroughASymlink() throws {
        let (base, logicalRoot, physicalRoot) = try makeSymlinkedRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        let p = project(name: "a", root: logicalRoot)

        // A shell/PWD probe can report the physical path even though the
        // project was registered through the symlink; both spellings match.
        #expect(matcher.project(for: physicalRoot, in: [p])?.id == p.id)
        #expect(matcher.project(for: physicalRoot + "/src", in: [p])?.id == p.id)
        #expect(matcher.projectOwningWorktree(for: physicalRoot + "/.worktrees/feature", in: [p])?.id == p.id)
        // The logical spelling keeps matching too.
        #expect(matcher.project(for: logicalRoot, in: [p])?.id == p.id)
        #expect(matcher.projectOwningWorktree(for: logicalRoot + "/.worktrees/feature", in: [p])?.id == p.id)
    }

    // MARK: - Nested projects across differently-sized registered forms

    /// Creates `base/p/.worktrees/inner/.worktrees/feature` plus `base/p/sub/src`
    /// on disk and a long-named `base/<alias> → base/p` symlink, so an outer
    /// project registered through the alias has a LONG logical spelling whose
    /// symlink-resolved form (`base/p`) is SHORTER than the nested inner
    /// project's registered paths.
    private func makeAliasedNestedRepos() throws -> (base: URL, outerAliasRoot: String, physicalOuterRoot: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for dir in ["p/sub/src", "p/.worktrees/inner/.worktrees/feature"] {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(dir),
                withIntermediateDirectories: true
            )
        }
        let alias = "really-long-alias-name-for-the-outer-project"
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent(alias),
            withDestinationURL: base.appendingPathComponent("p")
        )
        return (base, base.appendingPathComponent(alias).path, base.appendingPathComponent("p").path)
    }

    @Test func nestedProjectBeatsOuterProjectMatchedThroughLongerAlias() throws {
        let (base, outerAliasRoot, physicalOuterRoot) = try makeAliasedNestedRepos()
        defer { try? FileManager.default.removeItem(at: base) }
        let outer = project(name: "outer", root: outerAliasRoot)
        let inner = project(name: "inner", root: physicalOuterRoot + "/sub")

        // The workspace sits inside inner, which nests inside outer's physical
        // root. Outer matches only through its symlink-resolved form (short),
        // but its logical alias spelling is longer than inner's whole path —
        // ranking by logical length would wrongly hand the workspace to outer.
        let workspace = physicalOuterRoot + "/sub/src"
        #expect(matcher.project(for: workspace, in: [outer, inner])?.id == inner.id)
        #expect(matcher.project(for: workspace, in: [inner, outer])?.id == inner.id)
        // Outside inner, outer still owns its physical subtree via the alias.
        #expect(matcher.project(for: physicalOuterRoot + "/other", in: [outer, inner])?.id == outer.id)
    }

    @Test func nestedWorktreeOwnerBeatsOuterProjectMatchedThroughLongerAlias() throws {
        let (base, outerAliasRoot, physicalOuterRoot) = try makeAliasedNestedRepos()
        defer { try? FileManager.default.removeItem(at: base) }
        let outer = project(name: "outer", root: outerAliasRoot)
        let inner = project(name: "inner", root: physicalOuterRoot + "/.worktrees/inner")

        // Inner is itself registered inside outer's worktrees dir. A checkout
        // in INNER's worktrees dir lies under both projects' worktrees dirs;
        // the deeper matched dir (inner's) must win even though outer's
        // logical worktrees-dir spelling (through the alias) is longer.
        let workspace = physicalOuterRoot + "/.worktrees/inner/.worktrees/feature"
        #expect(matcher.projectOwningWorktree(for: workspace, in: [outer, inner])?.id == inner.id)
        #expect(matcher.projectOwningWorktree(for: workspace, in: [inner, outer])?.id == inner.id)
        // A sibling checkout directly in outer's worktrees dir still nests under outer.
        let sibling = physicalOuterRoot + "/.worktrees/feature"
        #expect(matcher.projectOwningWorktree(for: sibling, in: [outer, inner])?.id == outer.id)
    }

    @Test func resolvedDirectoryConvergesLogicalAndPhysicalSpellings() throws {
        let (base, logicalRoot, physicalRoot) = try makeSymlinkedRepo()
        defer { try? FileManager.default.removeItem(at: base) }

        let resolvedLogical = SupermuxProjectMatcher.resolvedDirectory(logicalRoot)
        let resolvedPhysical = SupermuxProjectMatcher.resolvedDirectory(physicalRoot)
        #expect(resolvedLogical == resolvedPhysical)
        #expect(resolvedLogical != SupermuxProjectMatcher.normalizedDirectory(logicalRoot))
    }
}

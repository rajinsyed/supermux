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

    @Test func resolvedDirectoryConvergesLogicalAndPhysicalSpellings() throws {
        let (base, logicalRoot, physicalRoot) = try makeSymlinkedRepo()
        defer { try? FileManager.default.removeItem(at: base) }

        let resolvedLogical = SupermuxProjectMatcher.resolvedDirectory(logicalRoot)
        let resolvedPhysical = SupermuxProjectMatcher.resolvedDirectory(physicalRoot)
        #expect(resolvedLogical == resolvedPhysical)
        #expect(resolvedLogical != SupermuxProjectMatcher.normalizedDirectory(logicalRoot))
    }
}

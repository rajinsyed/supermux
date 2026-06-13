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
}

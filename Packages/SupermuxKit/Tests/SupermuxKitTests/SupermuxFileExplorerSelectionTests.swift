import Testing

@testable import SupermuxKit

@Suite struct SupermuxFileExplorerSelectionTests {
    @Test func authoritativeKeepsOnlyStoreSelectedPaths() {
        // Visual selection sits on the parent (e.g. during a reveal gap) but the
        // authoritative selection is the new child — only the child is returned.
        let result = SupermuxFileExplorerSelection.authoritativePaths(
            visible: ["/a"], authoritative: ["/a/new.txt"]
        )
        #expect(result.isEmpty)
    }

    @Test func authoritativePreservesVisualOrderForMatches() {
        let result = SupermuxFileExplorerSelection.authoritativePaths(
            visible: ["/a/x", "/a/y", "/a/z"], authoritative: ["/a/z", "/a/x"]
        )
        #expect(result == ["/a/x", "/a/z"])
    }

    @Test func authoritativeEmptyWhenNoStoreSelection() {
        let result = SupermuxFileExplorerSelection.authoritativePaths(
            visible: ["/a", "/b"], authoritative: []
        )
        #expect(result.isEmpty)
    }

    @Test func authoritativeMatchesWhenVisualEqualsStore() {
        let result = SupermuxFileExplorerSelection.authoritativePaths(
            visible: ["/a", "/b"], authoritative: ["/a", "/b"]
        )
        #expect(result == ["/a", "/b"])
    }
}

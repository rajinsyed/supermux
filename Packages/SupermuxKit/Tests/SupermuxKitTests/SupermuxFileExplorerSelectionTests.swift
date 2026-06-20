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

    // MARK: - contextTargetPaths

    @Test func contextUsesSelectionWhenClickedRowIsSelected() {
        let result = SupermuxFileExplorerSelection.contextTargetPaths(
            clickedPath: "/a", clickedRowIsSelected: true, selectedPaths: ["/a", "/b"]
        )
        #expect(result == ["/a", "/b"])
    }

    @Test func contextUsesClickedAloneWhenNotInSelection() {
        let result = SupermuxFileExplorerSelection.contextTargetPaths(
            clickedPath: "/c", clickedRowIsSelected: false, selectedPaths: ["/a", "/b"]
        )
        #expect(result == ["/c"])
    }

    @Test func contextUsesClickedAloneWhenSelectionEmpty() {
        let result = SupermuxFileExplorerSelection.contextTargetPaths(
            clickedPath: "/c", clickedRowIsSelected: true, selectedPaths: []
        )
        #expect(result == ["/c"])
    }

    // MARK: - fileOpAction

    @Test func fileOpActionStaleIgnoresAndDoesNotRefresh() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: true, didFail: true, revealPath: "/x")
        #expect(a == .ignore)
        #expect(a.refreshesTree == false)
    }

    @Test func fileOpActionFailurePresentsErrorAndRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: true, revealPath: nil)
        #expect(a == .presentError)
        #expect(a.refreshesTree)   // the tree MUST refresh even after a (partial) failure
    }

    @Test func fileOpActionSuccessRevealsAndRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: false, revealPath: "/new")
        #expect(a == .reveal("/new"))
        #expect(a.refreshesTree)
    }

    @Test func fileOpActionSuccessWithoutRevealStillRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: false, revealPath: nil)
        #expect(a == .reveal(nil))
        #expect(a.refreshesTree)
    }

    // MARK: - revealAfterTrash

    @Test func revealAfterTrashReturnsParentForNestedItem() {
        #expect(SupermuxFileExplorerSelection.revealAfterTrash(
            firstParentPath: "/repo/src", rootPath: "/repo") == "/repo/src")
    }

    @Test func revealAfterTrashReturnsNilWhenParentIsRoot() {
        #expect(SupermuxFileExplorerSelection.revealAfterTrash(
            firstParentPath: "/repo", rootPath: "/repo") == nil)
    }

    @Test func revealAfterTrashReturnsNilWhenNoParent() {
        #expect(SupermuxFileExplorerSelection.revealAfterTrash(
            firstParentPath: nil, rootPath: "/repo") == nil)
    }
}

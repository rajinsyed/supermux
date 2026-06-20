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
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: true, didFail: true, reveal: .reveal("/x"))
        #expect(a == .ignore)
        #expect(a.refreshesTree == false)
    }

    @Test func fileOpActionFailurePresentsErrorAndRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: true, reveal: .none)
        #expect(a == .presentError)
        #expect(a.refreshesTree)   // the tree MUST refresh even after a (partial) failure
    }

    @Test func fileOpActionSuccessRevealsAndRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: false, reveal: .reveal("/new"))
        #expect(a == .apply(.reveal("/new")))
        #expect(a.refreshesTree)
    }

    @Test func fileOpActionSuccessWithClearStillRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: false, reveal: .clearSelection)
        #expect(a == .apply(.clearSelection))
        #expect(a.refreshesTree)
    }

    @Test func fileOpActionSuccessWithNoneStillRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: false, reveal: .none)
        #expect(a == .apply(.none))
        #expect(a.refreshesTree)
    }

    // MARK: - revealAfterTrash

    @Test func revealAfterTrashRevealsParentForNestedItem() {
        #expect(SupermuxFileExplorerSelection.revealAfterTrash(
            firstParentPath: "/repo/src", rootPath: "/repo") == .reveal("/repo/src"))
    }

    @Test func revealAfterTrashClearsWhenParentIsRoot() {
        #expect(SupermuxFileExplorerSelection.revealAfterTrash(
            firstParentPath: "/repo", rootPath: "/repo") == .clearSelection)
    }

    @Test func revealAfterTrashClearsWhenNoParent() {
        #expect(SupermuxFileExplorerSelection.revealAfterTrash(
            firstParentPath: nil, rootPath: "/repo") == .clearSelection)
    }
}

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
    }

    @Test func fileOpActionFailurePresentsErrorAndRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: true, reveal: .none)
        #expect(a == .presentError)
    }

    @Test func fileOpActionSuccessRevealsAndRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: false, reveal: .reveal("/new"))
        #expect(a == .apply(.reveal("/new")))
    }

    @Test func fileOpActionSuccessWithClearStillRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: false, reveal: .clearSelection)
        #expect(a == .apply(.clearSelection))
    }

    @Test func fileOpActionSuccessWithNoneStillRefreshes() {
        let a = SupermuxFileExplorerSelection.fileOpAction(isStale: false, didFail: false, reveal: .none)
        #expect(a == .apply(.none))
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

    // MARK: - revealForCreatedItem / revealForRenamedItem

    @Test func createdVisibleItemIsRevealed() {
        #expect(SupermuxFileExplorerSelection.revealForCreatedItem(
            path: "/repo/new.txt", showHiddenFiles: false) == .reveal("/repo/new.txt"))
    }

    @Test func createdHiddenItemIsNotRevealedWhenHiddenFilesOff() {
        // A hidden name never appears in the tree, so a reveal would dangle;
        // unlike rename there is no old path to clear, so the selection is kept.
        #expect(SupermuxFileExplorerSelection.revealForCreatedItem(
            path: "/repo/.env", showHiddenFiles: false) == FileOpReveal.none)
    }

    @Test func createdHiddenItemIsRevealedWhenHiddenFilesOn() {
        #expect(SupermuxFileExplorerSelection.revealForCreatedItem(
            path: "/repo/.env", showHiddenFiles: true) == .reveal("/repo/.env"))
    }

    @Test func createdItemWithHiddenAncestorButVisibleNameIsRevealed() {
        // Only the item's own name decides; a dotted ancestor is the tree's concern.
        #expect(SupermuxFileExplorerSelection.revealForCreatedItem(
            path: "/repo/.config/list.txt", showHiddenFiles: false) == .reveal("/repo/.config/list.txt"))
    }

    @Test func renamedVisibleItemIsRevealed() {
        #expect(SupermuxFileExplorerSelection.revealForRenamedItem(
            path: "/repo/new.txt", showHiddenFiles: false) == .reveal("/repo/new.txt"))
    }

    @Test func renamedToHiddenNameClearsSelectionWhenHiddenFilesOff() {
        // The old path is gone; leaving it selected would dead-end ⌘⌫/Return.
        #expect(SupermuxFileExplorerSelection.revealForRenamedItem(
            path: "/repo/.env", showHiddenFiles: false) == .clearSelection)
    }

    @Test func renamedToHiddenNameIsRevealedWhenHiddenFilesOn() {
        #expect(SupermuxFileExplorerSelection.revealForRenamedItem(
            path: "/repo/.env", showHiddenFiles: true) == .reveal("/repo/.env"))
    }

    // MARK: - explicitRefreshIsRedundant

    @Test func refreshIsRedundantWhenEveryParentIsTheWatchedRoot() {
        #expect(SupermuxFileExplorerSelection.explicitRefreshIsRedundant(
            mutatedParentPaths: ["/repo", "/repo"], rootPath: "/repo", rootIsWatched: true))
    }

    @Test func refreshIsRequiredForSubdirectoryParents() {
        // The root watcher is non-recursive: a subdirectory mutation is invisible.
        #expect(!SupermuxFileExplorerSelection.explicitRefreshIsRedundant(
            mutatedParentPaths: ["/repo/src"], rootPath: "/repo", rootIsWatched: true))
    }

    @Test func refreshIsRequiredWhenAnyParentIsOutsideTheRoot() {
        // Mixed multi-selection: one root-level and one nested parent.
        #expect(!SupermuxFileExplorerSelection.explicitRefreshIsRedundant(
            mutatedParentPaths: ["/repo", "/repo/src"], rootPath: "/repo", rootIsWatched: true))
    }

    @Test func refreshIsRequiredWithoutARootWatcher() {
        #expect(!SupermuxFileExplorerSelection.explicitRefreshIsRedundant(
            mutatedParentPaths: ["/repo"], rootPath: "/repo", rootIsWatched: false))
    }

    @Test func refreshIsRequiredForEmptyInputsFailSafe() {
        #expect(!SupermuxFileExplorerSelection.explicitRefreshIsRedundant(
            mutatedParentPaths: [], rootPath: "/repo", rootIsWatched: true))
        #expect(!SupermuxFileExplorerSelection.explicitRefreshIsRedundant(
            mutatedParentPaths: ["/repo"], rootPath: "", rootIsWatched: true))
    }
}

/// Local alias so `.none` disambiguates from `Optional.none` in `#expect`.
private typealias FileOpReveal = SupermuxFileExplorerSelection.FileOpReveal

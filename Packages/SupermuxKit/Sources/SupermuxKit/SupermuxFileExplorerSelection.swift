/// Pure selection-resolution helpers for the file-explorer file operations.
///
/// These exist so the *decision* logic behind destructive actions is unit-tested
/// without a running AppKit outline view; the app layer is a thin adapter.
public enum SupermuxFileExplorerSelection {
    /// The subset of the *visual* selection that is also in the *authoritative*
    /// (store) selection, preserving the visual order.
    ///
    /// Destructive keyboard actions (⌘⌫ trash, Return rename) use this so a
    /// transient visual selection — which can land on a parent folder while a
    /// just-created item's row is still loading during a reveal — can never act
    /// on the wrong target. An empty authoritative set yields an empty result
    /// (act on nothing) rather than falling back to the raw visual selection.
    public static func authoritativePaths(visible: [String], authoritative: Set<String>) -> [String] {
        visible.filter { authoritative.contains($0) }
    }

    /// Targets for a node context action (Duplicate / Move to Trash): the whole
    /// selection when the clicked row is part of the current selection, otherwise
    /// just the clicked item (right-clicking an unselected row acts on that row).
    public static func contextTargetPaths(
        clickedPath: String,
        clickedRowIsSelected: Bool,
        selectedPaths: [String]
    ) -> [String] {
        guard clickedRowIsSelected, !selectedPaths.isEmpty else { return [clickedPath] }
        return selectedPaths
    }

    /// What to do with the explorer selection after a successful file operation.
    public enum FileOpReveal: Equatable, Sendable {
        /// Leave the selection unchanged (e.g. a duplicate with nothing to reveal).
        case none
        /// Select and scroll this path into view (a created/renamed/copied item).
        case reveal(String)
        /// Clear the selection so the next reload auto-selects a default. Used by
        /// root-level trash, where there is no surviving parent row to select and
        /// the deleted path must not linger as the authoritative selection
        /// (`reload()` alone does NOT clear it).
        case clearSelection
    }

    /// What to apply on the main actor after an async file operation completes.
    public enum FileOpAction: Equatable, Sendable {
        /// The workspace changed under the (reused) store mid-op: touch nothing.
        case ignore
        /// Success: apply the reveal, then refresh the tree.
        case apply(FileOpReveal)
        /// Failure: surface the error, then refresh the tree.
        case presentError

        /// Whether the tree must be reloaded for this action (everything but `ignore`).
        public var refreshesTree: Bool { self != .ignore }
    }

    /// Reconciles an async file op's result against a possible mid-op workspace
    /// switch. Extracted so the "refresh even after a failure, but not after a
    /// stale-workspace switch" contract is unit-tested, not buried in AppKit glue.
    public static func fileOpAction(isStale: Bool, didFail: Bool, reveal: FileOpReveal) -> FileOpAction {
        if isStale { return .ignore }
        if didFail { return .presentError }
        return .apply(reveal)
    }

    /// What to do with the selection after trashing: select the first trashed
    /// item's parent, unless that parent is the explorer root (or there is none) —
    /// then clear the selection. Keeps the post-trash selection off the now-deleted
    /// path so the next ⌘⌫/Return doesn't dead-end (the root-level case).
    public static func revealAfterTrash(firstParentPath: String?, rootPath: String) -> FileOpReveal {
        guard let firstParentPath, firstParentPath != rootPath else { return .clearSelection }
        return .reveal(firstParentPath)
    }
}

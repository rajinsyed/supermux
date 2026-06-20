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

    /// What to apply on the main actor after an async file operation completes.
    public enum FileOpAction: Equatable, Sendable {
        /// The workspace changed under the (reused) store mid-op: touch nothing.
        case ignore
        /// Success: reveal this path (if any), then refresh the tree.
        case reveal(String?)
        /// Failure: surface the error, then refresh the tree.
        case presentError

        /// Whether the tree must be reloaded for this action (everything but `ignore`).
        public var refreshesTree: Bool { self != .ignore }
    }

    /// Reconciles an async file op's result against a possible mid-op workspace
    /// switch. Extracted so the "refresh even after a failure, but not after a
    /// stale-workspace switch" contract is unit-tested, not buried in AppKit glue.
    public static func fileOpAction(isStale: Bool, didFail: Bool, revealPath: String?) -> FileOpAction {
        if isStale { return .ignore }
        if didFail { return .presentError }
        return .reveal(revealPath)
    }

    /// The path to select/reveal after trashing: the first trashed item's parent,
    /// unless that parent is the explorer root (then nil — there is no root row to
    /// select, so selection simply clears on reload). Keeps the post-trash
    /// selection off the now-deleted path so the next ⌘⌫/Return doesn't dead-end.
    public static func revealAfterTrash(firstParentPath: String?, rootPath: String) -> String? {
        guard let firstParentPath, firstParentPath != rootPath else { return nil }
        return firstParentPath
    }
}

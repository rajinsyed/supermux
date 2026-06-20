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
}

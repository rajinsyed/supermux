import Foundation

/// Visible-row availability around one flat-list workspace row, used to enable
/// or disable Move Up/Down and Close Other/Below/Above in the row's context
/// menu. Project-hidden workspaces (rendered nested in the Projects section)
/// do not count as visible, so the menu enablement mirrors the hidden-row-aware
/// stepping and close scoping of the actions themselves.
///
/// Computed by the sidebar owner (which holds `TabManager`) on demand at menu
/// open, and handed across the lazy-list snapshot boundary as a plain value —
/// rows never observe a store to derive it.
struct SupermuxRowMenuVisibility: Equatable {
    let hasVisibleAbove: Bool
    let hasVisibleBelow: Bool
    let hasOtherVisibleWorkspaces: Bool

    /// Upstream-equivalent behavior for construction sites that do not wire
    /// the supermux projects section (unit tests): everything enabled.
    static let allVisible = SupermuxRowMenuVisibility(
        hasVisibleAbove: true,
        hasVisibleBelow: true,
        hasOtherVisibleWorkspaces: true
    )
}

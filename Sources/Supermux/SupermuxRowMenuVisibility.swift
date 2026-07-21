import Foundation

/// Visible-row availability around one flat-list workspace row, used to enable
/// or disable Move Up/Down and Close Other/Below/Above in the row's context
/// menu. Project-hidden workspaces (rendered nested in the Projects section)
/// do not count as visible, so the menu enablement mirrors the hidden-row-aware
/// stepping and close scoping of the actions themselves.
///
/// Move and close enablement are computed separately: a visible row above is
/// always a valid *close* target, but not always a valid *move* destination —
/// the reorder clamp (pin tier, group section) can make the only visible
/// neighbor unreachable, so `canMoveUp`/`canMoveDown` come from the same
/// stepped-plan check the move itself uses
/// (`TabManager.supermuxSteppedReorderTarget`), keeping the menu and the
/// mutation in agreement.
///
/// Computed by the sidebar owner (which holds `TabManager`) on demand at menu
/// open, and handed across the lazy-list snapshot boundary as a plain value —
/// rows never observe a store to derive it.
struct SupermuxRowMenuVisibility: Equatable {
    let hasVisibleAbove: Bool
    let hasVisibleBelow: Bool
    let hasOtherVisibleWorkspaces: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool

    /// Upstream-equivalent behavior for construction sites that do not wire
    /// the supermux projects section (unit tests): everything enabled.
    static let allVisible = SupermuxRowMenuVisibility(
        hasVisibleAbove: true,
        hasVisibleBelow: true,
        hasOtherVisibleWorkspaces: true,
        canMoveUp: true,
        canMoveDown: true
    )
}

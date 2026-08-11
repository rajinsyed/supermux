public import SwiftUI

/// Everything the iOS workspace table needs in order to render the fork's
/// Projects section in one hosted row.
///
/// The shell's table configuration is a plain value struct that the coordinator
/// diffs on every update, so the fork's payload has to answer three questions
/// cheaply and without exposing a store across the boundary:
///
/// - what to draw (``section`` + ``actions``),
/// - whether the drawing changed (``section``, `Equatable`),
/// - whether the row's HEIGHT changed (``layoutIdentity``).
///
/// Splitting the last two is the point. Agent activity, PR state, run state and
/// unread flags repaint rows constantly at identical size; re-measuring this
/// subtree on each of those would push the whole section through
/// `systemLayoutSizeFitting` during live agent output — exactly the work the
/// exact-height table exists to avoid.
public struct SupermuxProjectsTableRowConfiguration {
    /// The section's value snapshot.
    public let section: SupermuxProjectsSectionSnapshot
    /// The closure bundle the hosted rows act through.
    public let actions: SupermuxProjectsSectionActions
    /// What the row's measured height depends on. See
    /// ``SupermuxProjectsTableLayoutIdentity``.
    public let layoutIdentity: SupermuxProjectsTableLayoutIdentity

    /// Builds the row payload, or `nil` when the section must not render at
    /// all — no live session, or a host without `supermux.projects.v1`. A
    /// `nil` payload means the table emits no Projects row whatsoever, so a
    /// fork phone paired with an upstream Mac shows exactly upstream's list.
    /// - Parameters:
    ///   - section: The section's value snapshot.
    ///   - actions: The closure bundle rows act through.
    public init?(
        section: SupermuxProjectsSectionSnapshot,
        actions: SupermuxProjectsSectionActions
    ) {
        guard section.isVisible else { return nil }
        self.section = section
        self.actions = actions
        self.layoutIdentity = SupermuxProjectsTableLayoutIdentity(
            section: section,
            canEdit: actions.editing != nil
        )
    }

    /// Whether the hosted content must be redrawn.
    ///
    /// Compares the value snapshot plus the seams' PRESENCE — the closure
    /// bundles themselves are not `Equatable`, and their identity changes on
    /// every model projection, so comparing them would force a repaint on
    /// every tick. This mirrors how the shell compares its own closure-valued
    /// configuration fields.
    /// - Parameters:
    ///   - previous: The previously applied payload, if any.
    ///   - next: The payload about to be applied, if any.
    public static func renderChanged(
        previous: SupermuxProjectsTableRowConfiguration?,
        next: SupermuxProjectsTableRowConfiguration?
    ) -> Bool {
        guard let previous, let next else { return (previous == nil) != (next == nil) }
        return previous.section != next.section
            || (previous.actions.editing != nil) != (next.actions.editing != nil)
            || (previous.actions.run != nil) != (next.actions.run != nil)
            // The New Worktree preparation spinner is carried on the actions
            // bundle (it is UI-transient, not section data), so its change
            // must repaint the hosted subtree like any value change would.
            || previous.actions.preparingNewWorktreeProjectID
                != next.actions.preparingNewWorktreeProjectID
    }

    /// The row's height-cache identity, as a string the shell can fold into
    /// its own cache key. Stable while only paint-level state changes.
    public var heightIdentity: String {
        layoutIdentity.fingerprint
    }
}

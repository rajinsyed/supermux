public import Foundation
public import Observation

/// Shared drag-reorder state for the Projects sidebar section, threaded from the
/// section down to its rows.
///
/// This is a reference ``Observation/Observable`` — deliberately **not** value
/// `@State` on the section — for one specific reason: SwiftUI re-runs the body
/// of whatever view *owns* a value `@State` on every write to it. If the dragged
/// id lived in the section's `@State`, setting it at drag start would re-run the
/// section's `ForEach`, recreate the row that just started the drag, and cancel
/// the gesture (the "drag won't start / row stays dimmed" bug).
///
/// With an `@Observable` reference, a write to ``draggingProjectId`` /
/// ``draggingWorkspaceId`` invalidates **only the views that read that property**
/// (the dragged row's `opacity`), never the section body or its `ForEach`. The
/// row updates its dim in place and the drag survives. This mirrors cmux's
/// `SidebarDragState`. Because it changes only at drag start/end (twice per
/// drag), it does not reintroduce the orthogonal-`@Published` row-thrash that the
/// sidebar snapshot-boundary rule guards against.
@MainActor
@Observable
public final class SupermuxSidebarDragState {
    /// The project currently being dragged for reorder, or `nil`.
    public var draggingProjectId: UUID?
    /// The nested workspace currently being dragged for reorder, or `nil`.
    public var draggingWorkspaceId: UUID?

    /// Creates an idle drag state.
    public init() {}

    /// Clears any in-flight drag marker (drop complete, abort, or failsafe).
    public func clear() {
        draggingProjectId = nil
        draggingWorkspaceId = nil
    }
}

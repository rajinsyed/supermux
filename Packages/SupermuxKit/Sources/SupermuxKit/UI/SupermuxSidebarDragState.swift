public import Foundation
public import Observation

/// The transient project display order previewed while a project reorder drag
/// is in flight, plus the project being dragged (needed to translate the final
/// order back into one model move on commit).
public struct SupermuxProjectOrderPreview: Equatable, Sendable {
    /// The project the user is dragging.
    public let draggedProjectId: UUID
    /// The full previewed display order (all project ids).
    public let order: [UUID]

    /// Creates a preview.
    public init(draggedProjectId: UUID, order: [UUID]) {
        self.draggedProjectId = draggedProjectId
        self.order = order
    }
}

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
///
/// Project reorders are additionally previewed here (``projectOrderPreview``)
/// rather than mutated live into the model: hovering across N rows would
/// otherwise persist the projects file N times per drag. The section renders
/// from the preview while dragging and commits it to the model **once**, via
/// ``commitProjectOrder``, when ``clear()`` runs at drag end.
@MainActor
@Observable
public final class SupermuxSidebarDragState {
    /// The project currently being dragged for reorder, or `nil`.
    public var draggingProjectId: UUID?
    /// The nested workspace currently being dragged for reorder, or `nil`.
    public var draggingWorkspaceId: UUID?
    /// The in-flight project drag's previewed display order, or `nil` when no
    /// reorder has been previewed. Set lazily on the first hover-move (never at
    /// drag start, which must not invalidate the section body).
    public private(set) var projectOrderPreview: SupermuxProjectOrderPreview?
    /// Commits a finished drag's previewed order to the model. Wired by the
    /// owning section (which maps it to one `moveProject` + persist); invoked
    /// exactly once per previewed drag, from ``clear()``.
    @ObservationIgnored public var commitProjectOrder: ((SupermuxProjectOrderPreview) -> Void)?

    /// Creates an idle drag state.
    public init() {}

    /// Whether any drag marker or uncommitted reorder preview is set. Cheap to
    /// poll from event monitors (reads outside a SwiftUI body register no
    /// observation dependency).
    public var hasActiveDrag: Bool {
        draggingProjectId != nil || draggingWorkspaceId != nil || projectOrderPreview != nil
    }

    /// Previews moving `dragged` over `target`: the dragged project lands after
    /// the target when moving down, before it when moving up — mirroring
    /// `SupermuxProjectsModel.moveProject(_:over:)`, which the commit replays.
    /// - Parameters:
    ///   - dragged: Project being dragged.
    ///   - target: Project the dragged row is hovering over.
    ///   - baseOrder: Current model order, used to seed the first preview.
    public func previewProjectMove(dragged: UUID, over target: UUID, baseOrder: [UUID]) {
        var order = projectOrderPreview?.order ?? baseOrder
        guard dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        let targetIndex = order.firstIndex(of: target) ?? order.endIndex
        order.insert(dragged, at: to > from ? targetIndex + 1 : targetIndex)
        projectOrderPreview = SupermuxProjectOrderPreview(draggedProjectId: dragged, order: order)
    }

    /// Ends any in-flight drag: commits a previewed project order (once) and
    /// clears the drag markers. Runs on every drag-*finishing* release — a
    /// delivered drop and a release off any row alike — so the order the user
    /// last saw previewed is what persists. Each property is only written when
    /// it is actually set, so an idle clear (every mouse-up reaches the
    /// failsafe) never fires an Observation mutation and never re-renders rows.
    public func clear() {
        if let preview = projectOrderPreview {
            // Nil the preview first so the commit's model reorder re-renders
            // the section straight from the (identical) committed order.
            projectOrderPreview = nil
            commitProjectOrder?(preview)
        }
        if draggingProjectId != nil { draggingProjectId = nil }
        if draggingWorkspaceId != nil { draggingWorkspaceId = nil }
    }

    /// Cancels any in-flight drag: discards the previewed order — the rows
    /// snap back to the model's persisted order — and clears the drag markers.
    /// Escape is a cancel gesture, so it must never persist the preview the
    /// way a release does; the mouse-up that eventually follows the cancelled
    /// drag session finds no active drag and no-ops.
    public func cancel() {
        if projectOrderPreview != nil { projectOrderPreview = nil }
        if draggingProjectId != nil { draggingProjectId = nil }
        if draggingWorkspaceId != nil { draggingWorkspaceId = nil }
    }

    /// The single `moveProject(dragged, over:)` target that reproduces
    /// `previewOrder` from `currentOrder`, or `nil` when the dragged project's
    /// position is unchanged (or no longer resolvable).
    ///
    /// Only the dragged project ever moves relative to the others, so one move
    /// suffices: when it moved down the target is its previewed predecessor
    /// (`moveProject` inserts after a lower target), when it moved up the
    /// target is its previewed follower (inserts before a higher target).
    /// Projects added or removed mid-drag are tolerated by restricting the
    /// preview to ids still present in `currentOrder`.
    /// - Parameters:
    ///   - dragged: The dragged project.
    ///   - previewOrder: The final previewed display order.
    ///   - currentOrder: The model's current order.
    nonisolated static func commitTarget(
        dragged: UUID,
        previewOrder: [UUID],
        currentOrder: [UUID]
    ) -> UUID? {
        guard let from = currentOrder.firstIndex(of: dragged),
              let previewIndex = previewOrder.firstIndex(of: dragged) else { return nil }
        let liveIds = Set(currentOrder)
        let othersBefore = previewOrder[..<previewIndex].filter { liveIds.contains($0) && $0 != dragged }
        let othersAfter = previewOrder[(previewIndex + 1)...].filter { liveIds.contains($0) && $0 != dragged }
        if othersBefore.count == from { return nil }
        if othersBefore.count > from { return othersBefore.last }
        return othersAfter.first
    }
}

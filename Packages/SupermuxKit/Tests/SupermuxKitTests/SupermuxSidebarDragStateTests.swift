import Foundation
import Testing
@testable import SupermuxKit

/// Tests the project drag-reorder preview: hover-moves mutate only in-memory
/// state, and drag end commits exactly one `(dragged, over)` model move that
/// reproduces the previewed order.
@MainActor
struct SupermuxSidebarDragStateTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    // MARK: Preview reorder math (mirrors SupermuxProjectsModel.moveProject)

    @Test func previewMovesDownAfterTarget() {
        let state = SupermuxSidebarDragState()
        state.previewProjectMove(dragged: a, over: c, baseOrder: [a, b, c, d])
        #expect(state.projectOrderPreview?.order == [b, c, a, d])
        #expect(state.projectOrderPreview?.draggedProjectId == a)
    }

    @Test func previewMovesUpBeforeTarget() {
        let state = SupermuxSidebarDragState()
        state.previewProjectMove(dragged: c, over: a, baseOrder: [a, b, c, d])
        #expect(state.projectOrderPreview?.order == [c, a, b, d])
    }

    @Test func previewChainsAcrossHoverMoves() {
        let state = SupermuxSidebarDragState()
        state.previewProjectMove(dragged: a, over: b, baseOrder: [a, b, c, d])
        #expect(state.projectOrderPreview?.order == [b, a, c, d])
        // The second hover-move builds on the first preview, not the base order.
        state.previewProjectMove(dragged: a, over: c, baseOrder: [a, b, c, d])
        #expect(state.projectOrderPreview?.order == [b, c, a, d])
    }

    @Test func previewIgnoresSelfAndUnknownIds() {
        let state = SupermuxSidebarDragState()
        state.previewProjectMove(dragged: a, over: a, baseOrder: [a, b])
        state.previewProjectMove(dragged: UUID(), over: b, baseOrder: [a, b])
        #expect(state.projectOrderPreview == nil)
    }

    // MARK: Commit target (single-move translation)

    /// Replays `SupermuxProjectsModel.moveProject` semantics: remove dragged,
    /// insert after the target when it sat lower, before it when higher.
    private func applyMove(_ dragged: UUID, over target: UUID, to order: [UUID]) -> [UUID] {
        guard dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return order }
        var reordered = order
        reordered.remove(at: from)
        let targetIndex = reordered.firstIndex(of: target) ?? reordered.endIndex
        reordered.insert(dragged, at: to > from ? targetIndex + 1 : targetIndex)
        return reordered
    }

    @Test func commitTargetReproducesPreviewOrder() {
        let current = [a, b, c, d]
        // Every single-element move of every element is reproduced exactly.
        for dragged in current {
            for finalIndex in 0..<current.count {
                var preview = current.filter { $0 != dragged }
                preview.insert(dragged, at: finalIndex)
                let target = SupermuxSidebarDragState.commitTarget(
                    dragged: dragged, previewOrder: preview, currentOrder: current
                )
                if preview == current {
                    #expect(target == nil)
                } else {
                    let committed = target.map { applyMove(dragged, over: $0, to: current) }
                    #expect(committed == preview)
                }
            }
        }
    }

    @Test func commitTargetToleratesProjectsChangedMidDrag() {
        // A project (d) was removed and another (e) added while dragging.
        let e = UUID()
        let preview = [b, a, c, d]          // dragged a below b, d has since gone
        let current = [a, b, c, e]
        let target = SupermuxSidebarDragState.commitTarget(
            dragged: a, previewOrder: preview, currentOrder: current
        )
        #expect(target == b)
        #expect(applyMove(a, over: b, to: current) == [b, a, c, e])
    }

    @Test func commitTargetToleratesInsertionBeforeDraggedMidDrag() {
        // A project (x) appeared *before* the dragged project while dragging
        // (e.g. a sibling instance's file edit adopted mid-drag). The inflated
        // raw index must not turn the previewed move into a false no-op.
        let x = UUID()
        let preview = [b, a, c]             // dragged a below b
        let current = [x, a, b, c]          // x inserted at the front mid-drag
        let target = SupermuxSidebarDragState.commitTarget(
            dragged: a, previewOrder: preview, currentOrder: current
        )
        #expect(target == b)
        #expect(applyMove(a, over: b, to: current) == [x, b, a, c])
    }

    @Test func commitTargetToleratesMultipleInsertionsBeforeDragged() {
        // Enough insertions before the dragged project to flip the raw-index
        // comparison past "unchanged" — the target must stay the previewed
        // predecessor (c), not a follower on the wrong side.
        let x = UUID()
        let y = UUID()
        let z = UUID()
        let preview = [b, c, a, d]          // dragged a below c
        let current = [x, y, z, a, b, c, d]
        let target = SupermuxSidebarDragState.commitTarget(
            dragged: a, previewOrder: preview, currentOrder: current
        )
        #expect(target == c)
        #expect(applyMove(a, over: c, to: current) == [x, y, z, b, c, a, d])
    }

    @Test func commitTargetNilForUnknownDragged() {
        #expect(SupermuxSidebarDragState.commitTarget(
            dragged: UUID(), previewOrder: [a, b], currentOrder: [a, b]
        ) == nil)
    }

    // MARK: clear() commit semantics

    @Test func clearCommitsPreviewExactlyOnce() {
        let state = SupermuxSidebarDragState()
        var commits: [SupermuxProjectOrderPreview] = []
        state.commitProjectOrder = { commits.append($0) }
        state.draggingProjectId = a
        state.previewProjectMove(dragged: a, over: b, baseOrder: [a, b])

        state.clear()
        #expect(commits.map(\.order) == [[b, a]])
        #expect(state.projectOrderPreview == nil)
        #expect(state.draggingProjectId == nil)

        // The failsafe may clear again on the next mouse-up; it must not
        // re-commit or re-dirty anything.
        state.clear()
        #expect(commits.count == 1)
        #expect(state.hasActiveDrag == false)
    }

    @Test func clearWithoutPreviewCommitsNothing() {
        let state = SupermuxSidebarDragState()
        var commits = 0
        state.commitProjectOrder = { _ in commits += 1 }
        state.draggingWorkspaceId = a
        state.clear()
        #expect(commits == 0)
        #expect(state.draggingWorkspaceId == nil)
    }

    // MARK: cancel() semantics (Escape)

    /// Escape is a cancel gesture: the previewed order must be discarded, not
    /// persisted — the rows snap back to the model's order.
    @Test func cancelDiscardsPreviewWithoutCommitting() {
        let state = SupermuxSidebarDragState()
        var commits = 0
        state.commitProjectOrder = { _ in commits += 1 }
        state.draggingProjectId = a
        state.previewProjectMove(dragged: a, over: b, baseOrder: [a, b])

        state.cancel()
        #expect(commits == 0)
        #expect(state.projectOrderPreview == nil)
        #expect(state.draggingProjectId == nil)
        #expect(state.hasActiveDrag == false)

        // The mouse-up that follows the cancelled drag session reaches the
        // failsafe's clear(); with the preview gone it must not commit either.
        state.clear()
        #expect(commits == 0)
    }

    @Test func hasActiveDragTracksMarkersAndPreview() {
        let state = SupermuxSidebarDragState()
        #expect(state.hasActiveDrag == false)
        state.draggingProjectId = a
        #expect(state.hasActiveDrag)
        state.clear()
        #expect(state.hasActiveDrag == false)
        state.previewProjectMove(dragged: a, over: b, baseOrder: [a, b])
        #expect(state.hasActiveDrag)
    }
}

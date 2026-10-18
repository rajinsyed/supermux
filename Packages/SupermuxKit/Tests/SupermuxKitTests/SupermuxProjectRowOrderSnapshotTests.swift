import Foundation
import Testing

@testable import SupermuxKit

/// Ways the equatable row boundary could retain stale reorder callbacks:
/// 1. Remote-only neighbors swap while this local project and its move flags stay the same.
/// 2. A remote-only row joins or leaves while the local row remains movable in both directions.
/// 3. Refreshing an unchanged order invalidates every row unnecessarily.
@MainActor
struct SupermuxProjectRowOrderSnapshotTests {
    private let project = SupermuxProject(name: "Local", rootPath: "/local")
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    @Test func remoteNeighborsSwappingRefreshesTheLocalRowsCallbacks() {
        #expect(row([a, project.id, b, c]) != row([b, project.id, a, c]))
    }

    @Test func remoteRowsJoiningOrLeavingRefreshesTheDragBaseOrder() {
        let original = row([a, project.id, b])
        #expect(original != row([a, project.id, b, c]))
        #expect(original != row([a, project.id, c]))
    }

    @Test func anUnchangedOrderKeepsTheRowEqual() {
        #expect(row([a, project.id, b]) == row([a, project.id, b]))
    }

    private func row(_ order: [UUID]) -> SupermuxProjectRowView {
        SupermuxProjectRowView(
            project: project,
            worktrees: [],
            isExpanded: false,
            actions: SupermuxProjectRowActions(
                openLocal: {}, newWorktree: {}, openWorktree: { _ in },
                deleteWorktree: { _, _ in }, toggleExpanded: {}, edit: {},
                remove: {}, revealInFinder: {}, launchAction: { _ in },
                selectWorkspace: { _ in }, closeWorkspace: { _ in }
            ),
            canMoveUp: true,
            canMoveDown: true,
            projectOrder: order
        )
    }
}

import Foundation
import SupermuxKit
import Testing

/// Unit tests for `SupermuxWorkspaceSwitcherOrder`: the MRU bookkeeping, frozen
/// session order, and selection-index arithmetic that give the switcher its
/// app-switcher feel.
struct SupermuxWorkspaceSwitcherOrderTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    // MARK: - promote

    @Test func promoteMovesExistingIdToFront() {
        #expect(SupermuxWorkspaceSwitcherOrder.promote(b, in: [a, b, c]) == [b, a, c])
    }

    @Test func promoteInsertsAbsentIdAtFront() {
        #expect(SupermuxWorkspaceSwitcherOrder.promote(d, in: [a, b]) == [d, a, b])
    }

    @Test func promoteIsIdempotentForHead() {
        #expect(SupermuxWorkspaceSwitcherOrder.promote(a, in: [a, b, c]) == [a, b, c])
    }

    // MARK: - pruned

    @Test func prunedDropsClosedWorkspacesKeepingOrder() {
        let result = SupermuxWorkspaceSwitcherOrder.pruned([a, b, c], keeping: [a, c])
        #expect(result == [a, c])
    }

    @Test func prunedEmptyWhenNothingLive() {
        #expect(SupermuxWorkspaceSwitcherOrder.pruned([a, b], keeping: []).isEmpty)
    }

    // MARK: - sessionOrder

    @Test func sessionOrderPutsCurrentFirstThenMRU() {
        // Current = c; recency b, a; tabs order a, b, c, d.
        let order = SupermuxWorkspaceSwitcherOrder.sessionOrder(
            currentId: c,
            mru: [c, b, a],
            tabsOrder: [a, b, c, d]
        )
        // c first, then MRU (b, a), then never-seen d appended in tabs order.
        #expect(order == [c, b, a, d])
    }

    @Test func sessionOrderAppendsNeverSeenInTabsOrder() {
        let order = SupermuxWorkspaceSwitcherOrder.sessionOrder(
            currentId: a,
            mru: [a],
            tabsOrder: [a, b, c]
        )
        #expect(order == [a, b, c])
    }

    @Test func sessionOrderExcludesStaleMRUEntries() {
        // MRU references d which is no longer open; it must not appear.
        let order = SupermuxWorkspaceSwitcherOrder.sessionOrder(
            currentId: b,
            mru: [b, d, a],
            tabsOrder: [a, b, c]
        )
        #expect(order == [b, a, c])
        #expect(!order.contains(d))
    }

    @Test func sessionOrderHandlesNilCurrent() {
        let order = SupermuxWorkspaceSwitcherOrder.sessionOrder(
            currentId: nil,
            mru: [c, a],
            tabsOrder: [a, b, c]
        )
        #expect(order == [c, a, b])
    }

    @Test func sessionOrderIsAlwaysAPermutationOfLiveTabs() {
        let order = SupermuxWorkspaceSwitcherOrder.sessionOrder(
            currentId: c,
            mru: [c, b, a, d],
            tabsOrder: [a, b, c]
        )
        #expect(Set(order) == Set([a, b, c]))
        #expect(order.count == 3)
    }

    // MARK: - initialSelection

    @Test func initialSelectionForwardHighlightsPrevious() {
        #expect(SupermuxWorkspaceSwitcherOrder.initialSelection(count: 4, backward: false) == 1)
    }

    @Test func initialSelectionBackwardHighlightsLast() {
        #expect(SupermuxWorkspaceSwitcherOrder.initialSelection(count: 4, backward: true) == 3)
    }

    @Test func initialSelectionSingleWorkspaceIsZero() {
        #expect(SupermuxWorkspaceSwitcherOrder.initialSelection(count: 1, backward: false) == 0)
        #expect(SupermuxWorkspaceSwitcherOrder.initialSelection(count: 1, backward: true) == 0)
    }

    @Test func initialSelectionEmptyIsZero() {
        #expect(SupermuxWorkspaceSwitcherOrder.initialSelection(count: 0, backward: false) == 0)
    }

    // MARK: - advance

    @Test func advanceForwardWrapsAround() {
        #expect(SupermuxWorkspaceSwitcherOrder.advance(2, count: 3, backward: false) == 0)
        #expect(SupermuxWorkspaceSwitcherOrder.advance(0, count: 3, backward: false) == 1)
    }

    @Test func advanceBackwardWrapsAround() {
        #expect(SupermuxWorkspaceSwitcherOrder.advance(0, count: 3, backward: true) == 2)
        #expect(SupermuxWorkspaceSwitcherOrder.advance(2, count: 3, backward: true) == 1)
    }

    @Test func advanceEmptyIsZero() {
        #expect(SupermuxWorkspaceSwitcherOrder.advance(0, count: 0, backward: false) == 0)
    }

    // MARK: - remappedSelection

    @Test func remappedSelectionFollowsSelectedWorkspaceWhenEarlierEntryCloses() {
        // Order [a, b, c, d], highlight on b (index 1); a closes before the
        // overlay shows. The highlight must stay on b, not shift onto c.
        let index = SupermuxWorkspaceSwitcherOrder.remappedSelection(
            previousIndex: 1, previousOrder: [a, b, c, d], newOrder: [b, c, d]
        )
        #expect(index == 0)
    }

    @Test func remappedSelectionKeepsIdentityWhenLaterEntryCloses() {
        let index = SupermuxWorkspaceSwitcherOrder.remappedSelection(
            previousIndex: 1, previousOrder: [a, b, c, d], newOrder: [a, b, d]
        )
        #expect(index == 1)
    }

    @Test func remappedSelectionClampsWhenSelectedWorkspaceClosed() {
        // The highlighted workspace itself died: fall back to the clamped index.
        let index = SupermuxWorkspaceSwitcherOrder.remappedSelection(
            previousIndex: 3, previousOrder: [a, b, c, d], newOrder: [a, b, c]
        )
        #expect(index == 2)
    }

    @Test func remappedSelectionIsUnchangedWhenOrderIsUnchanged() {
        let index = SupermuxWorkspaceSwitcherOrder.remappedSelection(
            previousIndex: 2, previousOrder: [a, b, c], newOrder: [a, b, c]
        )
        #expect(index == 2)
    }

    @Test func remappedSelectionHandlesOutOfRangePreviousIndex() {
        let index = SupermuxWorkspaceSwitcherOrder.remappedSelection(
            previousIndex: 9, previousOrder: [a, b], newOrder: [a, b]
        )
        #expect(index == 1)
    }

    @Test func remappedSelectionEmptyNewOrderIsZero() {
        let index = SupermuxWorkspaceSwitcherOrder.remappedSelection(
            previousIndex: 1, previousOrder: [a, b], newOrder: []
        )
        #expect(index == 0)
    }

    // MARK: - quick-toggle behavior (the defining app-switcher feel)

    @Test func quickToggleReturnsToPreviousThenBack() {
        // Two workspaces, current = a, previous = b.
        let order = SupermuxWorkspaceSwitcherOrder.sessionOrder(
            currentId: a,
            mru: [a, b],
            tabsOrder: [a, b]
        )
        #expect(order == [a, b])
        // A quick tap+release lands on index 1 (the previous workspace, b).
        let selection = SupermuxWorkspaceSwitcherOrder.initialSelection(count: order.count, backward: false)
        #expect(order[selection] == b)
    }

    // MARK: - monogram

    @Test func monogramUsesFirstAlphanumeric() {
        #expect(SupermuxWorkspaceSwitcherItem.monogram(for: "cmux dev") == "C")
        #expect(SupermuxWorkspaceSwitcherItem.monogram(for: "  9to5") == "9")
    }

    @Test func monogramFallsBackToHash() {
        #expect(SupermuxWorkspaceSwitcherItem.monogram(for: "—!") == "#")
        #expect(SupermuxWorkspaceSwitcherItem.monogram(for: "") == "#")
    }
}

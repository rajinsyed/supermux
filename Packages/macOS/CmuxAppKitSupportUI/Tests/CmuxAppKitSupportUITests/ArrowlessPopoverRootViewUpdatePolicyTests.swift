#if canImport(AppKit)

import Testing
// SUPERMUX:begin popover-dynamic-height-reanchor
import SwiftUI
// SUPERMUX:end popover-dynamic-height-reanchor
@testable import CmuxAppKitSupportUI

@Suite struct ArrowlessPopoverRootViewUpdatePolicyTests {
    @Test func hiddenClosedPopoverDoesNotNeedHostedRootRefresh() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: false,
            popoverIsShown: false
        ) == .none)
    }

    @Test func firstPresentationUpdatesHostedRootSynchronously() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: true,
            popoverIsShown: false
        ) == .immediate)
    }

    @Test func visiblePopoverDefersHostedRootRefreshOutsideRepresentableUpdate() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: false,
            popoverIsShown: true
        ) == .deferredVisible)
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: true,
            popoverIsShown: true
        ) == .deferredVisible)
    }
}

// SUPERMUX:begin popover-dynamic-height-reanchor
@MainActor
@Suite struct ArrowlessPopoverVisibleLayoutMutationPlanTests {
    private typealias Coordinator = ArrowlessPopoverAnchor<EmptyView>.Coordinator

    @Test func visibleHeightChangeResizesAndReanchors() {
        #expect(Coordinator.visibleLayoutMutationPlan(
            currentContentSize: NSSize(width: 264, height: 180),
            fittingSize: NSSize(width: 264, height: 244),
            popoverIsShown: true
        ) == .resizeAndReanchor(NSSize(width: 264, height: 244)))
    }

    @Test func subpixelFittingJitterThatRoundsToCurrentSizeDoesNothing() {
        #expect(Coordinator.visibleLayoutMutationPlan(
            currentContentSize: NSSize(width: 264, height: 244),
            fittingSize: NSSize(width: 263.2, height: 243.4),
            popoverIsShown: true
        ) == .none)
    }

    @Test func hiddenOrInvalidPopoverDoesNotRequestVisibleReanchor() {
        #expect(Coordinator.visibleLayoutMutationPlan(
            currentContentSize: NSSize(width: 264, height: 180),
            fittingSize: NSSize(width: 264, height: 244),
            popoverIsShown: false
        ) == .none)
        #expect(Coordinator.visibleLayoutMutationPlan(
            currentContentSize: NSSize(width: 264, height: 180),
            fittingSize: .zero,
            popoverIsShown: true
        ) == .none)
    }
}
// SUPERMUX:end popover-dynamic-height-reanchor

@MainActor
@Suite struct CmuxPopoverVisibleUpdateSchedulerTests {
    @Test func visibleUpdatesRunAfterCurrentMainActorTurnAndCoalesce() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied: [String] = []

        scheduler.schedule { applied.append("first") }
        scheduler.schedule { applied.append("second") }

        #expect(applied.isEmpty)
        await Task.yield()
        #expect(applied == ["second"])
    }

    @Test func cancellationDropsPendingVisibleUpdate() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied = false

        scheduler.schedule { applied = true }
        scheduler.cancel()

        await Task.yield()
        #expect(applied == false)
    }

    @Test func cancelledTaskDoesNotClearRescheduledVisibleUpdate() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied: [String] = []

        scheduler.schedule { applied.append("cancelled") }
        scheduler.cancel()
        scheduler.schedule { applied.append("rescheduled") }

        await Task.yield()
        await Task.yield()
        #expect(applied == ["rescheduled"])
    }
}

#endif

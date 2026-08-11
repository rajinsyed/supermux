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

    // SUPERMUX:begin popover-dynamic-height-reanchor
    @Test func firstPresentationDefersHostedRootMutationOutsideRepresentableUpdate() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: true,
            popoverIsShown: false
        ) == .deferredPresentation)
    }

    @Test func dismissalSkipsHostedRootRefresh() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: false,
            popoverIsShown: true
        ) == .none)
    }
    // SUPERMUX:end popover-dynamic-height-reanchor

    @Test func visiblePopoverDefersHostedRootRefreshOutsideRepresentableUpdate() {
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

@MainActor
@Suite struct ArrowlessPopoverPresentationDeferralTests {
    private typealias Coordinator = ArrowlessPopoverAnchor<EmptyView>.Coordinator

    @Test func initialPresentationRunsAfterCurrentRepresentableUpdateTurn() async {
        var presentationCount = 0
        var coordinator: Coordinator?
        var anchorView: NSView?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            coordinator = Coordinator(
                isPresented: .constant(true),
                showPopover: { _, _, _, _ in
                    presentationCount += 1
                    continuation.resume()
                }
            )
            anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            coordinator?.anchorView = anchorView

            coordinator?.deferPresentation(
                rootView: AnyView(Text("Token Usage")),
                preferredEdge: .maxY,
                detachedGap: 4
            )
            #expect(presentationCount == 0)
        }

        #expect(presentationCount == 1)
        _ = coordinator
        _ = anchorView
    }

    @Test func dismissalBeforeDeferredPresentationCancelsTheShow() async {
        var presentationCount = 0
        let coordinator = Coordinator(
            isPresented: .constant(true),
            showPopover: { _, _, _, _ in presentationCount += 1 }
        )
        let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        coordinator.anchorView = anchorView

        coordinator.deferPresentation(
            rootView: AnyView(Text("Token Usage")),
            preferredEdge: .maxY,
            detachedGap: 4
        )
        coordinator.deferDismissal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }

        #expect(presentationCount == 0)
    }
}
// SUPERMUX:end popover-dynamic-height-reanchor

@MainActor
@Suite struct CmuxPopoverVisibleUpdateSchedulerTests {
    // SUPERMUX:begin popover-dynamic-height-reanchor
    @Test func visibleUpdatesRunOnNextMainRunLoopTurnAndCoalesce() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied: [String] = []

        scheduler.schedule { applied.append("first") }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduler.schedule {
                applied.append("second")
                continuation.resume()
            }
            #expect(applied.isEmpty)
        }

        #expect(applied == ["second"])
    }

    @Test func cancellationDropsPendingVisibleUpdate() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied = false

        scheduler.schedule { applied = true }
        scheduler.cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }

        #expect(applied == false)
    }

    @Test func cancelledCallbackDoesNotClearRescheduledVisibleUpdate() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied: [String] = []

        scheduler.schedule { applied.append("cancelled") }
        scheduler.cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduler.schedule {
                applied.append("rescheduled")
                continuation.resume()
            }
        }

        #expect(applied == ["rescheduled"])
    }
    // SUPERMUX:end popover-dynamic-height-reanchor
}

#endif

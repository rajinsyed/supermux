public import AppKit
public import SwiftUI

/// An `NSViewRepresentable` that presents SwiftUI content in an `NSPopover` with the
/// popover arrow hidden, anchored to an invisible SwiftUI-backed view.
///
/// The popover is positioned relative to a synthetic rect inset toward the anchor so the
/// detached content sits a fixed gap from the anchoring edge while the arrow stays hidden.
public struct ArrowlessPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding public var isPresented: Bool
    public let preferredEdge: NSRectEdge
    public let detachedGap: CGFloat
    private let presentationAnimation: CmuxPopoverPresentationAnimation
    private let group: CmuxPopoverGroup?
    @ViewBuilder public let content: () -> PopoverContent

    /// Creates an arrowless popover anchor.
    /// - Parameters:
    ///   - isPresented: Binding driving popover presentation.
    ///   - preferredEdge: The edge of the anchor the popover prefers to appear from.
    ///   - detachedGap: The gap, in points, between the anchor edge and the popover.
    ///   - presentationAnimation: The opening transition policy for this popover.
    ///   - group: Shared dismissal owner when this popover belongs to a nested menu.
    ///   - content: The SwiftUI content rendered inside the popover.
    public init(
        isPresented: Binding<Bool>,
        preferredEdge: NSRectEdge,
        detachedGap: CGFloat,
        presentationAnimation: CmuxPopoverPresentationAnimation = .automatic,
        group: CmuxPopoverGroup? = nil,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) {
        self._isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.detachedGap = detachedGap
        self.presentationAnimation = presentationAnimation
        self.group = group
        self.content = content
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchorView = nsView
        coordinator.updatePresentationBinding($isPresented)
        coordinator.updatePresentationAnimation(presentationAnimation)
        // SUPERMUX:begin popover-dynamic-height-reanchor
        // Never mutate an NSPopover or its hosted SwiftUI tree from inside this
        // representable update. AppKit can synchronously order child windows and
        // re-enter SwiftUI layout, corrupting the active Observation access list.
        switch ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: isPresented,
            popoverIsShown: coordinator.isPopoverShown
        ) {
        case .none:
            coordinator.cancelDeferredRootViewUpdate()
            coordinator.deferDismissal()
        case .deferredPresentation:
            coordinator.cancelDeferredRootViewUpdate()
            coordinator.deferPresentation(
                rootView: AnyView(content()),
                preferredEdge: preferredEdge,
                detachedGap: detachedGap
            )
        case .deferredVisible:
            coordinator.cancelDeferredPresentationUpdate()
            coordinator.deferVisibleRootViewUpdate(AnyView(content()))
        }
        // SUPERMUX:end popover-dynamic-height-reanchor
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            isPresented: $isPresented,
            presentationAnimation: presentationAnimation,
            group: group
        )
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss(resetPresentation: false)
    }

    /// Bridges popover lifecycle between AppKit's `NSPopover` and the SwiftUI binding.
    @MainActor
    public final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
        private var popover: NSPopover?
        private var closingPopovers: [ObjectIdentifier: NSPopover] = [:]
        private var pendingVisibleRootView: AnyView?
        private var presentationAnimation: CmuxPopoverPresentationAnimation
        private let group: CmuxPopoverGroup?
        private var groupMemberID: UUID?
        // SUPERMUX:begin popover-dynamic-height-reanchor
        typealias ShowPopover = @MainActor (NSPopover, NSRect, NSView, NSRectEdge) -> Void

        private let presentationUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
        private let layoutUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
        private let showPopover: ShowPopover
        private var pendingPresentationRootView: AnyView?
        private var currentPreferredEdge: NSRectEdge = .maxY
        private var currentDetachedGap: CGFloat = 0

        enum VisibleLayoutMutationPlan: Equatable {
            case none
            case resizeAndReanchor(NSSize)
        }

        static func visibleLayoutMutationPlan(
            currentContentSize: NSSize,
            fittingSize: NSSize,
            popoverIsShown: Bool
        ) -> VisibleLayoutMutationPlan {
            guard popoverIsShown, fittingSize.width > 0, fittingSize.height > 0 else {
                return .none
            }
            let targetSize = NSSize(
                width: ceil(fittingSize.width),
                height: ceil(fittingSize.height)
            )
            guard targetSize != currentContentSize else { return .none }
            return .resizeAndReanchor(targetSize)
        }
        // SUPERMUX:end popover-dynamic-height-reanchor
        var isPopoverShown: Bool { popover?.isShown == true }

        init(
            isPresented: Binding<Bool>,
            presentationAnimation: CmuxPopoverPresentationAnimation,
            group: CmuxPopoverGroup?,
            // SUPERMUX:begin popover-dynamic-height-reanchor
            showPopover: @escaping ShowPopover = { popover, positioningRect, anchorView, preferredEdge in
                popover.show(
                    relativeTo: positioningRect,
                    of: anchorView,
                    preferredEdge: preferredEdge
                )
            }
            // SUPERMUX:end popover-dynamic-height-reanchor
        ) {
            _isPresented = isPresented
            self.presentationAnimation = presentationAnimation
            self.group = group
            // SUPERMUX:begin popover-dynamic-height-reanchor
            self.showPopover = showPopover
            // SUPERMUX:end popover-dynamic-height-reanchor
        }

        // SUPERMUX:begin popover-dynamic-height-reanchor
        /// Ungrouped, automatic-animation coordinator with an injectable show seam (tests).
        convenience init(
            isPresented: Binding<Bool>,
            showPopover: @escaping ShowPopover
        ) {
            self.init(
                isPresented: isPresented,
                presentationAnimation: .automatic,
                group: nil,
                showPopover: showPopover
            )
        }

        func deferPresentation(
            rootView: AnyView,
            preferredEdge: NSRectEdge,
            detachedGap: CGFloat
        ) {
            pendingPresentationRootView = rootView
            currentPreferredEdge = preferredEdge
            currentDetachedGap = detachedGap
            layoutUpdateScheduler.cancel()
            presentationUpdateScheduler.schedule { [weak self] in
                self?.flushDeferredPresentationRootUpdate()
            }
        }

        func cancelDeferredPresentationUpdate() {
            pendingPresentationRootView = nil
            presentationUpdateScheduler.cancel()
            layoutUpdateScheduler.cancel()
        }

        func deferDismissal() {
            pendingPresentationRootView = nil
            layoutUpdateScheduler.cancel()
            guard popover != nil else {
                presentationUpdateScheduler.cancel()
                return
            }
            // The binding is already false on this path; rewriting it would be
            // a redundant binding write (upstream #13442 keeps it untouched).
            presentationUpdateScheduler.schedule { [weak self] in
                self?.dismiss(resetPresentation: false)
            }
        }

        private func flushDeferredPresentationRootUpdate() {
            guard isPresented, let pendingPresentationRootView else {
                self.pendingPresentationRootView = nil
                return
            }
            self.pendingPresentationRootView = nil
            updateRootView(pendingPresentationRootView)
            // Installing an NSHostingController root starts a SwiftUI render.
            // Measure and order its popover on a later run-loop turn so AppKit
            // cannot lay the hosting view out while that render is still active.
            layoutUpdateScheduler.schedule { [weak self] in
                self?.flushDeferredPresentationLayout()
            }
        }

        private func flushDeferredPresentationLayout() {
            guard isPresented else { return }
            present(
                preferredEdge: currentPreferredEdge,
                detachedGap: currentDetachedGap
            )
        }
        // SUPERMUX:end popover-dynamic-height-reanchor

        func updatePresentationBinding(_ binding: Binding<Bool>) {
            _isPresented = binding
        }

        func updatePresentationAnimation(_ animation: CmuxPopoverPresentationAnimation) {
            presentationAnimation = animation
        }

        // SUPERMUX:begin popover-dynamic-height-reanchor
        func updateRootView(_ rootView: AnyView) {
            CmuxPopoverMutation.performWithoutImplicitAnimation {
                hostingController.rootView = AnyView(rootView.fixedSize())
                hostingController.view.invalidateIntrinsicContentSize()
            }
        }
        // SUPERMUX:end popover-dynamic-height-reanchor

        func deferVisibleRootViewUpdate(_ rootView: AnyView) {
            pendingVisibleRootView = rootView
            visibleUpdateScheduler.schedule { [weak self] in
                self?.flushDeferredRootViewUpdate()
            }
        }

        func cancelDeferredRootViewUpdate() {
            pendingVisibleRootView = nil
            visibleUpdateScheduler.cancel()
        }

        private func flushDeferredRootViewUpdate() {
            guard popover?.isShown == true, let pendingVisibleRootView else {
                self.pendingVisibleRootView = nil
                return
            }
            self.pendingVisibleRootView = nil
            updateRootView(pendingVisibleRootView)
            // SUPERMUX:begin popover-dynamic-height-reanchor
            layoutUpdateScheduler.schedule { [weak self] in
                self?.resizeAndReanchorVisiblePopoverIfNeeded()
            }
            // SUPERMUX:end popover-dynamic-height-reanchor
        }

        func present(preferredEdge: NSRectEdge, detachedGap: CGFloat) {
            // SUPERMUX:begin popover-dynamic-height-reanchor
            currentPreferredEdge = preferredEdge
            currentDetachedGap = detachedGap
            // SUPERMUX:end popover-dynamic-height-reanchor
            guard let anchorView else {
                isPresented = false
                dismiss()
                return
            }

            let popover = popover ?? makePopover()
            if popover.isShown {
                return
            }

            popover.animates = presentationAnimation.animates(
                isGrouped: group != nil,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )

            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            let fittingSize = hostingController.view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                CmuxPopoverMutation.setContentSize(NSSize(
                    width: ceil(fittingSize.width),
                    height: ceil(fittingSize.height)
                ), on: popover)
            }

            // SUPERMUX:begin popover-dynamic-height-reanchor
            showPopover(
                popover,
                positioningRect(
                    for: anchorView.bounds,
                    preferredEdge: preferredEdge,
                    detachedGap: detachedGap
                ),
                anchorView,
                preferredEdge
            )
            // SUPERMUX:end popover-dynamic-height-reanchor
            if popover.isShown {
                groupMemberID = group?.register(popover: popover, anchor: anchorView)
            }
        }

        // SUPERMUX:begin popover-dynamic-height-reanchor
        private func resizeAndReanchorVisiblePopoverIfNeeded() {
            guard let popover,
                  let anchorView,
                  anchorView.window != nil else {
                return
            }
            hostingController.view.layoutSubtreeIfNeeded()
            guard case .resizeAndReanchor(let targetSize) = Self.visibleLayoutMutationPlan(
                currentContentSize: popover.contentSize,
                fittingSize: hostingController.view.fittingSize,
                popoverIsShown: popover.isShown
            ) else {
                return
            }

            CmuxPopoverMutation.setContentSize(targetSize, on: popover)
            // With the arrow hidden, resizing a shown NSPopover can retain the
            // old window origin. Showing an already-visible popover again is
            // AppKit's supported way to recompute its anchor position.
            CmuxPopoverMutation.performWithoutImplicitAnimation {
                popover.show(
                    relativeTo: positioningRect(
                        for: anchorView.bounds,
                        preferredEdge: currentPreferredEdge,
                        detachedGap: currentDetachedGap
                    ),
                    of: anchorView,
                    preferredEdge: currentPreferredEdge
                )
            }
        }
        // SUPERMUX:end popover-dynamic-height-reanchor

        func dismiss(resetPresentation: Bool = true) {
            cancelDeferredRootViewUpdate()
            // SUPERMUX:begin popover-dynamic-height-reanchor
            cancelDeferredPresentationUpdate()
            // SUPERMUX:end popover-dynamic-height-reanchor
            unregisterFromGroup()
            guard let popover else {
                if resetPresentation { isPresented = false }
                return
            }
            closingPopovers[ObjectIdentifier(popover)] = popover
            if group != nil { popover.animates = false }
            popover.performClose(nil)
            self.popover = nil
            if resetPresentation { isPresented = false }
        }

        public func popoverWillClose(_ notification: Notification) {
            guard let closing = notification.object as? NSPopover else { return }
            guard closing === popover || closingPopovers[ObjectIdentifier(closing)] != nil else { return }
            if closing === popover {
                unregisterFromGroup()
            }
        }

        private func unregisterFromGroup() {
            guard let id = groupMemberID else { return }
            groupMemberID = nil
            group?.unregister(id)
        }

        public func popoverDidClose(_ notification: Notification) {
            guard let closing = notification.object as? NSPopover else { return }
            if closingPopovers.removeValue(forKey: ObjectIdentifier(closing)) != nil { return }
            guard closing === popover else { return }
            cancelDeferredRootViewUpdate()
            // SUPERMUX:begin popover-dynamic-height-reanchor
            cancelDeferredPresentationUpdate()
            // SUPERMUX:end popover-dynamic-height-reanchor
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = group == nil ? .semitransient : .applicationDefined
            popover.animates = group == nil
            popover.setValue(true, forKeyPath: "shouldHideAnchor")
            popover.contentViewController = hostingController
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func positioningRect(
            for bounds: CGRect,
            preferredEdge: NSRectEdge,
            detachedGap: CGFloat
        ) -> CGRect {
            let hiddenArrowInset: CGFloat = 13
            let compensation = max(hiddenArrowInset - detachedGap, 0)

            switch preferredEdge {
            case .maxY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.maxY - compensation,
                    width: bounds.width,
                    height: compensation
                )
            case .minY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: compensation
                )
            case .maxX:
                return NSRect(
                    x: bounds.maxX - compensation,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            case .minX:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            @unknown default:
                return bounds
            }
        }
    }
}

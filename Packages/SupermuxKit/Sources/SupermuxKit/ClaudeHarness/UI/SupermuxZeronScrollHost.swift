//
//  SupermuxZeronScrollHost.swift
//  SupermuxKit
//
//  The macOS scroll primitive the stick spring cannot work without.
//  Plan risk **R1** — the highest-ranked fidelity risk in the port.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  WHY THIS FILE EXISTS
//  ═══════════════════════════════════════════════════════════════════════════
//
//  zeron's spring needs three things:
//
//    (a) a readable AND writable pixel scroll offset,
//    (b) a `maxOffset` for the bottom,
//    (c) a scroll callback that fires **ONLY for user input**.
//
//  SwiftUI gives (a) and (b) through `ScrollView` + `.scrollPosition` /
//  `onScrollGeometryChange`. **(c) does not exist.** `onScrollGeometryChange`
//  and `.scrollPosition` fire for PROGRAMMATIC scrolls too — and the spring
//  scrolls programmatically on every single frame it runs. Wire the pin-break
//  test to a geometry callback and the spring breaks its own pin on frame one:
//  the spring moves the view 16 pt down, the callback reports "the offset
//  changed", the pin-break test sees motion, the pin drops, and the transcript
//  stops following. Every frame. That is not a subtle degradation; the feature
//  simply does not work.
//
//  zeron states the same rule from the other side (`transcript.rs:1612-1617`):
//  "the list invokes this handler ONLY from its wheel/touch input path
//  (programmatic scroll_by/scroll_to never re-enter it)". mugen §1e phrases it
//  as "interrupt detection from USER INPUT (wheel deltaY<0, touch drag up), NOT
//  scrollbar position". Spec 07 §4.2 calls it "the single most important
//  semantic to preserve in the SwiftUI port".
//
//  ═══════════════════════════════════════════════════════════════════════════
//  HOW USER-INPUT-ONLY IS ACHIEVED HERE
//  ═══════════════════════════════════════════════════════════════════════════
//
//  Two independent mechanisms, belt and braces, because either alone has a hole:
//
//  1. **`NSScrollView.contentView` bounds observation + a programmatic-write
//     suppression flag.** Every programmatic write goes through the single
//     `setOffset(_:)` funnel, which sets `isProgrammatic = true` for the
//     duration of the write. `boundsDidChange` consults the flag and returns
//     early. This alone would be fragile — AppKit can coalesce a bounds change
//     to a later runloop turn — which is why there is a second mechanism.
//
//  2. **A real input-phase gate.** `NSScrollView` posts
//     `willStartLiveScroll` / `didLiveScroll` / `didEndLiveScroll` for
//     wheel/trackpad input, and `NSEvent.phase` / `.momentumPhase` distinguish a
//     finger-down gesture from its momentum tail. The host tracks
//     `isUserScrolling` from those notifications and from a local
//     `.scrollWheel` event monitor, and a bounds change is reported as USER
//     INPUT only while that flag is set. **Momentum counts as user input** —
//     zeron hit exactly this ("macOS trackpad momentum can even release-and-
//     restick within one gesture right after a send"), so the flag stays set
//     through `momentumPhase != []` and clears on `didEndLiveScroll` plus a
//     `momentumPhase == .ended`.
//
//  A callback therefore fires for a wheel notch, a two-finger drag, momentum
//  deceleration, a scroller-knob drag, and a keyboard page — and never for the
//  spring's own `scrollBy`.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  GEOMETRY AND SIGN CONVENTION
//  ═══════════════════════════════════════════════════════════════════════════
//
//  The document view is **flipped** (`isFlipped == true`), so `bounds.origin.y`
//  increases downward and `offset == 0` is the top. Then:
//
//      maxOffset = max(documentHeight - viewportHeight, 0)
//      offset    ∈ [0, maxOffset],  larger = closer to the BOTTOM
//      distance  = maxOffset - offset
//
//  which is exactly the spring's convention. zeron's own quantities differ only
//  in sign bookkeeping (`distance = max(maxOffset + currentOffset, 0)` with a
//  negative-going-up offset).
//
//  ═══════════════════════════════════════════════════════════════════════════
//  ORDERING RULE (spec 07 §8.5)
//  ═══════════════════════════════════════════════════════════════════════════
//
//  Never mutate scroll position synchronously inside a scroll callback: zeron
//  defers to the end of the effect cycle because the list holds an internal
//  borrow while calling out. The AppKit analogue is that AppKit is mid-update
//  when `boundsDidChange` fires. So the user-input callback is delivered to the
//  owner, and any correction the owner makes lands on the next display-link tick
//  — never re-entrantly.
//

public import AppKit
public import SwiftUI

// MARK: - Metrics snapshot

/// One post-layout reading of the scroll geometry.
///
/// A value type deliberately: the spring driver reads it once per tick, and a
/// snapshot cannot go stale mid-computation the way a live view query can.
public struct SupermuxZeronScrollMetrics: Sendable, Equatable {
    /// Current offset. `0` is the top; larger is closer to the bottom.
    public var offset: CGFloat
    /// `max(documentHeight - viewportHeight, 0)`.
    public var maxOffset: CGFloat
    /// The clip view's height.
    public var viewportHeight: CGFloat

    public init(offset: CGFloat, maxOffset: CGFloat, viewportHeight: CGFloat) {
        self.offset = offset
        self.maxOffset = maxOffset
        self.viewportHeight = viewportHeight
    }

    public static let zero = SupermuxZeronScrollMetrics(
        offset: 0, maxOffset: 0, viewportHeight: 0
    )

    /// `max(maxOffset - offset, 0)` — how far the viewport sits above the end.
    public var distanceFromBottom: CGFloat { max(maxOffset - offset, 0) }
}

// MARK: - Controller

/// The handle the spring driver and the transcript view talk to.
///
/// Held by the view model layer (ABOVE the `LazyVStack` boundary — no row view
/// ever sees it), so it survives row recycling and SwiftUI body churn.
@MainActor
public final class SupermuxZeronScrollController {
    /// The hosted scroll view, once mounted.
    fileprivate weak var scrollView: NSScrollView?

    /// Fires **only** for user input: wheel, trackpad drag, momentum,
    /// scroller-knob drag, keyboard paging. Never for a programmatic write.
    ///
    /// Delivered with the metrics AFTER the input landed. Do not scroll
    /// synchronously from here (see the ordering rule in this file's header).
    public var onUserScroll: ((SupermuxZeronScrollMetrics) -> Void)?

    /// Fires when the document or viewport size changes, i.e. when the spring's
    /// target may have moved. Not an input signal.
    public var onGeometryChange: ((SupermuxZeronScrollMetrics) -> Void)?

    /// True while a programmatic write is in flight. `boundsDidChange` early-
    /// returns on it, which is mechanism (1) from the header.
    fileprivate var isProgrammatic = false

    /// True while a user gesture (including its momentum tail) owns the
    /// viewport. This is mechanism (2), and it is the authoritative one.
    public fileprivate(set) var isUserScrolling = false

    public init() {}

    /// The current post-layout metrics, or `.zero` before mount.
    public var metrics: SupermuxZeronScrollMetrics {
        guard let scrollView else { return .zero }
        return Self.metrics(of: scrollView)
    }

    /// Sets the absolute offset, clamped to `[0, maxOffset]`.
    ///
    /// **The single funnel for every programmatic write.** Anything that bypasses
    /// it will be misread as user input and break the pin.
    public func setOffset(_ offset: CGFloat) {
        guard let scrollView else { return }
        let bounded = min(max(offset, 0), Self.metrics(of: scrollView).maxOffset)
        let clip = scrollView.contentView
        guard abs(clip.bounds.origin.y - bounded) > 0.001 else { return }
        isProgrammatic = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bounded))
        scrollView.reflectScrolledClipView(clip)
        // Cleared on the next runloop turn, not synchronously: AppKit may
        // deliver the resulting `boundsDidChange` after this call returns, and a
        // synchronous clear would let that notification through as "user input".
        //
        // `DispatchQueue.main.async` rather than `Task { @MainActor }` on
        // purpose — this must land on the NEXT main runloop turn, after AppKit
        // has drained its notifications. A `Task` hops through the cooperative
        // pool and can be scheduled either side of them, which would make the
        // suppression window non-deterministic.
        // carve-out: runloop-ordering requirement, see above.
        DispatchQueue.main.async { [weak self] in self?.isProgrammatic = false }
    }

    /// Relative scroll. Positive moves toward the bottom, matching
    /// `list.scroll_by(delta)` in zeron's spring driver.
    public func scrollBy(_ delta: CGFloat) {
        setOffset(metrics.offset + delta)
    }

    /// Jumps to the very bottom with no animation. The reduced-motion and
    /// first-fill path (`list.scroll_to_end()`).
    public func scrollToEnd() {
        setOffset(metrics.maxOffset)
    }

    fileprivate static func metrics(of scrollView: NSScrollView) -> SupermuxZeronScrollMetrics {
        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        return SupermuxZeronScrollMetrics(
            offset: scrollView.contentView.bounds.origin.y,
            maxOffset: max(documentHeight - viewportHeight, 0),
            viewportHeight: viewportHeight
        )
    }
}

// MARK: - Representable

/// An `NSScrollView` host exposing a pixel offset, a `maxOffset`, and a
/// user-input-only scroll callback.
///
/// Deliberately NOT a SwiftUI `ScrollView`: see the header. The content is still
/// ordinary SwiftUI, hosted in an `NSHostingView`, so the row views are shared
/// with iOS unchanged.
public struct SupermuxZeronScrollHost<Content: View>: NSViewRepresentable {
    private let controller: SupermuxZeronScrollController
    private let content: Content

    public init(
        controller: SupermuxZeronScrollController,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.content = content()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SupermuxZeronClippingScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Overlay scrollers float; a legacy scroller would eat column width and
        // shift the centred 736 pt column by its own thickness.
        scrollView.scrollerStyle = .overlay
        // The bounce is AppKit's, not the spring's. Leaving it on means a
        // rubber-band overscroll can push the offset past `maxOffset`, which the
        // spring's `min(pos, target)` clamp already tolerates.
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The document must be exactly the viewport's width so the SwiftUI
        // column centres against the real available width, and must size its
        // own height from content.
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.intrinsicContentSize]
        }

        let document = SupermuxZeronFlippedClipDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: document.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        context.coordinator.attach(scrollView: scrollView, hosting: hosting)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(content: AnyView(content))
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: Coordinator

    @MainActor
    public final class Coordinator: NSObject {
        private let controller: SupermuxZeronScrollController
        private weak var scrollView: NSScrollView?
        private weak var hosting: NSHostingView<AnyView>?
        private var wheelMonitor: Any?
        /// The document height at the last geometry report, so a pure offset
        /// change does not masquerade as a target move.
        private var lastReportedMaxOffset: CGFloat = -1
        private var lastReportedViewportHeight: CGFloat = -1

        init(controller: SupermuxZeronScrollController) {
            self.controller = controller
        }

        func attach(scrollView: NSScrollView, hosting: NSHostingView<AnyView>) {
            self.scrollView = scrollView
            self.hosting = hosting
            controller.scrollView = scrollView

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            center.addObserver(
                self,
                selector: #selector(frameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: scrollView.documentView
            )
            scrollView.documentView?.postsFrameChangedNotifications = true
            // The live-scroll notifications are the primary input gate. They
            // cover wheel, trackpad drag, and scroller-knob drag.
            center.addObserver(
                self,
                selector: #selector(willStartLiveScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            center.addObserver(
                self,
                selector: #selector(didEndLiveScroll(_:)),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )

            // The momentum tail arrives AFTER `didEndLiveScroll`, and it must
            // still count as user input — otherwise a flick toward the bottom
            // re-pins mid-flight, which zeron hit and documented. A local
            // monitor is the only place the momentum phase is visible.
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.noteWheel(event)
                return event
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
            if controller.scrollView === scrollView { controller.scrollView = nil }
            scrollView = nil
            hosting = nil
        }

        func update(content: AnyView) {
            hosting?.rootView = content
        }

        // MARK: Input gate

        private func noteWheel(_ event: NSEvent) {
            guard let scrollView, event.window === scrollView.window else { return }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                controller.isUserScrolling = false
            } else if !event.momentumPhase.isEmpty {
                // Momentum IS user input (spec 07 §8.1).
                controller.isUserScrolling = true
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                // A gesture that ends with no momentum. `didEndLiveScroll` also
                // fires here; whichever lands first clears the flag.
                controller.isUserScrolling = false
            } else {
                // `.began`, `.changed`, and legacy mouse wheels (phase == []).
                controller.isUserScrolling = true
            }
        }

        @objc private func willStartLiveScroll(_ notification: Notification) {
            controller.isUserScrolling = true
        }

        @objc private func didEndLiveScroll(_ notification: Notification) {
            // Do NOT clear the flag while momentum is still running: the wheel
            // monitor owns that transition. Clearing unconditionally here would
            // drop it at the exact moment a flick's momentum begins, and the
            // momentum tail would then be misread as "not user input" — which is
            // how a flick toward the bottom re-pins mid-flight, the failure
            // zeron documents ("macOS trackpad momentum can even
            // release-and-restick within one gesture right after a send").
            let event = NSApp.currentEvent
            let momentumRunning = event?.type == .scrollWheel
                && !(event?.momentumPhase.isEmpty ?? true)
            if !momentumRunning { controller.isUserScrolling = false }
        }

        // MARK: Notifications

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let scrollView else { return }
            // Mechanism (1): a programmatic write never reports as input.
            guard !controller.isProgrammatic else { return }
            // Mechanism (2): and neither does anything that is not a live user
            // gesture — a layout-driven bounds change, an accessibility scroll,
            // or an AppKit-internal correction.
            guard controller.isUserScrolling else { return }
            controller.onUserScroll?(SupermuxZeronScrollController.metrics(of: scrollView))
        }

        @objc private func frameDidChange(_ notification: Notification) {
            guard let scrollView else { return }
            let metrics = SupermuxZeronScrollController.metrics(of: scrollView)
            // Only report a real target move. A pure offset change already went
            // through `boundsDidChange`, and re-reporting it here would wake the
            // spring on every scroll frame.
            guard metrics.maxOffset != lastReportedMaxOffset
                || metrics.viewportHeight != lastReportedViewportHeight
            else { return }
            lastReportedMaxOffset = metrics.maxOffset
            lastReportedViewportHeight = metrics.viewportHeight
            controller.onGeometryChange?(metrics)
        }
    }
}

// MARK: - Flipped document

/// A flipped container so `bounds.origin.y == 0` is the TOP and increases
/// downward, which is the spring's convention (`larger = closer to the bottom`).
///
/// Without this, AppKit's default bottom-left origin inverts every comparison in
/// the spring and the restick band ends up measuring the wrong edge.
private final class SupermuxZeronFlippedClipDocument: NSView {
    override var isFlipped: Bool { true }
}

/// An `NSScrollView` that never draws a background.
///
/// The transcript composites over real behind-window glass; any opaque fill in
/// the scroll view's own draw path would replace the blur with a slab, which is
/// the same failure the edge fade exists to avoid.
private final class SupermuxZeronClippingScrollView: NSScrollView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Deliberately empty: no background, no divider.
    }
}

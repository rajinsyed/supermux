//
//  SupermuxZeronAnchoredMenu.swift
//  SupermuxZeronUI
//
//  The anchored-popover container: `anchored_menu_above_end` + `MENU_IN` /
//  `MENU_OUT`. Spec 08 §3.1–§3.5.
//
//  ── Why not `.popover()` ──
//
//  SwiftUI's `.popover()` is system chrome: an arrow, a system material, a
//  system corner radius and a system shadow, none of which are zeron's. The
//  card here is a plain overlay in the trigger's own coordinate space.
//
//  ── The anchor ──
//
//  gpui `Anchor::BottomRight` on a zero-size pin at the trigger's TOP-RIGHT
//  corner: the menu opens **upward**, right-aligned to the chip's right edge,
//  with a **6 pt** gap, clamped to **8 pt** from every window edge. "The menu's
//  right edge sits flush with the chip's right edge (user request)"
//  (`pickers.rs:3574`), and t3code's `ComboboxPopup align="end"` — right-side
//  triggers open leftward instead of running off the window.
//
//  ── The double-toggle guard ──
//
//  This is the subtle part and it must be ported (spec 08 §3.5, SwiftUI note in
//  §7). A tap outside begins the dismiss on the **same press** that will
//  produce the trigger's click, so by mouse-up the menu already reads closed and
//  a naive toggle immediately reopens it. Fix: the trigger's press records
//  whether the menu was mounted, and the click consumes that note. A press on a
//  DIFFERENT trigger does not count, so clicking another chip **switches** menus
//  rather than swallowing the click.
//
//  ── MENU_IN opacity starts at 0.3, not 0 ──
//
//  `.transition(.opacity)` starts at 0, so the entrance is built by hand from
//  the catalog's `menuInOpacityFloor` (0.3) and `menuInRise` (−2). A menu
//  popping in from zero reads slower, which is the whole reason for the floor.
//

public import SwiftUI

#if canImport(AppKit)
internal import AppKit
#elseif canImport(UIKit)
internal import UIKit
#endif

// MARK: - Press guard

/// The `note_trigger_press` / `take_press_was_open` guard.
///
/// Owned by the shell (one per chip cluster) and shared by every trigger in it,
/// so switching between chips works. `@MainActor` because every mutation
/// happens in a gesture callback.
@MainActor
@Observable
public final class SupermuxZeronMenuPressGuard {
    /// The menu identity that was mounted when the current press began.
    private var pressedWhileOpen: String?

    public init() {}

    /// Call from the trigger's **press** (mouse-down), before the dismiss has a
    /// chance to run: records whether `identity`'s menu was mounted.
    ///
    /// Open and mid-exit both count as mounted, which is what makes a click
    /// during the close animation dismiss rather than re-open.
    public func notePress(identity: String, isMounted: Bool) {
        pressedWhileOpen = isMounted ? identity : nil
    }

    /// Call from the trigger's **click**: `true` when this trigger's own menu
    /// was mounted at press time, meaning the click should close, not open.
    ///
    /// Consumes the note — a second read returns `false`.
    public func takePressWasOpen(identity: String) -> Bool {
        defer { pressedWhileOpen = nil }
        return pressedWhileOpen == identity
    }
}

// MARK: - Anchored menu

/// Mounts `card` above the trigger, right-aligned, with the zeron entrance.
///
/// Attach to the **trigger**, not to the card:
///
/// ```swift
/// chip.supermuxZeronAnchoredMenu(isPresented: $showsPicker) {
///     SupermuxZeronPickerCard(...)
/// }
/// ```
public struct SupermuxZeronAnchoredMenu<Card: View>: ViewModifier {
    @Binding private var isPresented: Bool
    private let identity: String
    private let pressGuard: SupermuxZeronMenuPressGuard?
    private let gap: CGFloat
    private let windowMargin: CGFloat
    private let card: () -> Card

    @State private var hasEntered = false
    /// Whether the card is in the tree at all. Outlives `isPresented` by the
    /// length of `MENU_OUT`, which is what lets the exit play.
    @State private var isMounted = false
    /// Mounted but on its way out: still painting, hit-testing dead.
    @State private var isClosing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - identity: this menu's key in the shared press guard. Two triggers in
    ///     one cluster must use DIFFERENT identities, or clicking the second
    ///     while the first is open swallows the click instead of switching.
    ///   - pressGuard: the cluster's shared guard. `nil` opts out — correct for
    ///     a lone menu with no sibling triggers.
    public init(
        isPresented: Binding<Bool>,
        identity: String = "menu",
        pressGuard: SupermuxZeronMenuPressGuard? = nil,
        gap: CGFloat = 6,
        windowMargin: CGFloat = 8,
        @ViewBuilder card: @escaping () -> Card
    ) {
        self._isPresented = isPresented
        self.identity = identity
        self.pressGuard = pressGuard
        self.gap = gap
        self.windowMargin = windowMargin
        self.card = card
        // A menu presented on first render (a restored state, a preview) still
        // has to be in the tree before `onChange` ever fires.
        self._isMounted = State(initialValue: isPresented.wrappedValue)
    }

    public func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if isMounted {
                // A zero-size pin at the trigger's top-right corner. The pin is
                // load-bearing: an absolutely-positioned element without
                // explicit insets inherits the trigger's flex alignment, so an
                // `items_center` trigger would vertically center the whole
                // floating layer (`popover.rs:328–341`).
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .bottomTrailing) {
                        anchoredCard
                    }
                    // The gap sits between the card's bottom edge and the
                    // trigger's top edge.
                    .offset(y: -gap)
                    // zeron's `on_mouse_down_out` (`pickers.rs:2412`): a press
                    // anywhere outside the card dismisses it. Without this the
                    // only exits are Escape and a re-click on the trigger — and
                    // the press guard below is unreachable, because the bug it
                    // fixes is *caused* by this dismissal racing the trigger's
                    // click.
                    .background {
                        SupermuxZeronOutsidePressCatcher(isActive: !isClosing) {
                            pressGuard?.notePress(identity: identity, isMounted: true)
                            isPresented = false
                        }
                    }
            }
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                isClosing = false
                isMounted = true
            } else {
                beginClose()
            }
        }
    }

    /// The three-state lifecycle: **open** → **closing** (still painting, hit
    /// testing dead) → **closed** (unmounted). gpui drops an element the frame
    /// its state clears, which is the whole reason `Popup` holds the value alive
    /// through the exit; SwiftUI has the same problem and the same fix.
    private func beginClose() {
        guard isMounted, !isClosing else {
            isMounted = false
            return
        }
        guard !reduceMotion else {
            isMounted = false
            hasEntered = false
            return
        }
        isClosing = true
        withAnimation(SupermuxZeronMetrics.Motion.menuOut.animation) {
            hasEntered = false
        }
        // MENU_OUT is 100 ms — deliberately quicker than the 140 ms entrance
        // ("exits should get out of the way"). Unmount after it, plus zeron's
        // own 20 ms of `reap_popup` slack.
        let total = SupermuxZeronMetrics.Motion.menuOut.totalDuration + 0.02
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(total))
            // A reopen during the exit keeps the card alive; the newer phase
            // owns its own teardown (`finish_close` re-checks the same way).
            guard isClosing else { return }
            isClosing = false
            isMounted = false
        }
    }

    private var anchoredCard: some View {
        card()
            .opacity(hasEntered ? 1 : SupermuxZeronMetrics.Motion.menuInOpacityFloor)
            .offset(y: hasEntered ? 0 : SupermuxZeronMetrics.Motion.menuInRise)
            // The card floats above everything, and a click on it must not also
            // fire whatever sits underneath.
            .zIndex(1)
            // A dying card's rows must not take clicks, and strays must not
            // reach what sits beneath it (zeron lays an `.occlude()` overlay
            // over the exiting card for exactly this).
            .allowsHitTesting(!isClosing)
            .modifier(SupermuxZeronWindowClamp(margin: windowMargin))
            .onAppear {
                guard !hasEntered else { return }
                if reduceMotion {
                    // A oneshot snaps to its END state under Reduce Motion.
                    hasEntered = true
                } else {
                    withAnimation(SupermuxZeronMetrics.Motion.menuIn.animation) {
                        hasEntered = true
                    }
                }
            }
            .onDisappear { hasEntered = false }
    }
}

// MARK: - Outside press

/// Fires once for a press that lands outside the mounted card.
///
/// A full-screen `Color` behind the card would work but would also swallow the
/// press it intercepts, so the very click that dismisses could never also act on
/// what it hit. A local monitor observes the press without consuming it, which
/// is what `on_mouse_down_out` does: it dismisses, and the press continues on to
/// whatever is under it (that is precisely why the trigger needs the press
/// guard). iOS has no equivalent monitor, so it dismisses on the card's own
/// container instead — see the platform branch.
private struct SupermuxZeronOutsidePressCatcher: View {
    let isActive: Bool
    let onOutsidePress: () -> Void

    var body: some View {
        #if canImport(AppKit)
        SupermuxZeronOutsidePressMonitor(isActive: isActive, onOutsidePress: onOutsidePress)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        #else
        // iOS never mounts THIS modifier: plan §4 presents the picker in a sheet
        // at `.presentationDetents([.height(346)])`, and a sheet owns its own
        // outside-dismissal. Nothing to catch.
        EmptyView()
        #endif
    }
}

#if canImport(AppKit)

/// An `NSEvent` local monitor for presses outside the card's own bounds.
private struct SupermuxZeronOutsidePressMonitor: NSViewRepresentable {
    let isActive: Bool
    let onOutsidePress: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onOutsidePress = onOutsidePress
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? MonitorView else { return }
        view.onOutsidePress = onOutsidePress
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? MonitorView)?.stop()
    }

    final class MonitorView: NSView {
        var onOutsidePress: (() -> Void)?
        var isActive = true { didSet { isActive ? start() : stop() } }

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stop() : start()
        }

        func start() {
            guard monitor == nil, isActive, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                // The event is RETURNED unmodified: dismissing must not eat the
                // press, or a click on another control would be swallowed.
                self?.handle(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard isActive, let window, event.window === window else { return }
            // The probe is a zero-size child of the card, so the CARD's bounds
            // are the superview's.
            guard let card = superview else { return }
            let point = card.convert(event.locationInWindow, from: nil)
            guard !card.bounds.contains(point) else { return }
            onOutsidePress?()
        }

        // No `deinit` teardown: an `NSEvent` monitor token is not `Sendable` and
        // cannot be touched from a nonisolated deinit under Swift 6. The monitor
        // is removed on the two transitions that actually matter —
        // `dismantleNSView` and losing the window — both of which are
        // main-actor and both of which precede deallocation here.
    }
}

#endif

// MARK: - Window clamp

/// `.snap_to_window_with_margin(8)` — never closer than `margin` to any **window**
/// edge.
///
/// ── Why this measures in AppKit/UIKit space and not through `GeometryReader` ──
///
/// The obvious implementation reads `proxy.frame(in: .global)` and clamps it
/// against `NSScreen.main.visibleFrame`. That is wrong twice over: `.global` is
/// the hosting view's space, not the screen's, and `visibleFrame` is a
/// screen-space rect with a **bottom-left** origin and a non-zero origin under
/// the menu bar. Comparing the two clamps against a rectangle that has no
/// relationship to the window, so a card in a window anywhere but the top-left
/// of a full-height display gets nudged for no reason — or not nudged when it
/// actually overflows.
///
/// zeron clamps to the WINDOW (`snap_to_window_with_margin`), so this probes the
/// real one: the platform view reports both its own frame and the window's
/// content bounds **in the same window space**, and the resulting correction is
/// converted back to SwiftUI's y-down convention.
struct SupermuxZeronWindowClamp: ViewModifier {
    let margin: CGFloat

    @State private var correction: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .offset(correction)
            .background {
                // The probe reports geometry; the state write happens in the
                // callback, never from `body` (the cmux #2586 rule).
                SupermuxZeronWindowProbe { frame, container in
                    let next = Self.correction(
                        for: frame, in: container, current: correction, margin: margin
                    )
                    if next != correction { correction = next }
                }
            }
    }

    /// The offset that pulls `frame` back inside `container`, keeping `margin`.
    ///
    /// The current correction is undone before measuring so the function is
    /// idempotent — otherwise each pass would compound the previous nudge. Both
    /// rects arrive in the same y-DOWN space (the probe flips AppKit's), so the
    /// result can be handed straight to `.offset`.
    static func correction(
        for frame: CGRect,
        in container: CGRect,
        current: CGSize,
        margin: CGFloat
    ) -> CGSize {
        let natural = frame.offsetBy(dx: -current.width, dy: -current.height)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        // Overflow on the far edge is corrected first, then the near edge wins a
        // tie — a card wider than the window stays pinned to the leading/top
        // margin rather than sliding off the other way.
        if natural.maxX > container.maxX - margin { dx = (container.maxX - margin) - natural.maxX }
        if natural.minX + dx < container.minX + margin { dx = (container.minX + margin) - natural.minX }
        if natural.maxY > container.maxY - margin { dy = (container.maxY - margin) - natural.maxY }
        if natural.minY + dy < container.minY + margin { dy = (container.minY + margin) - natural.minY }
        return CGSize(width: dx, height: dy)
    }
}

// MARK: - Window probe

/// Reports `(this view's frame, the window's content bounds)` in one shared
/// y-DOWN coordinate space, whenever either changes.
private struct SupermuxZeronWindowProbe: View {
    let onMeasure: (CGRect, CGRect) -> Void

    var body: some View {
        SupermuxZeronWindowProbeRepresentable(onMeasure: onMeasure)
            // Zero-size and non-interactive: it exists to read geometry, and a
            // background that took hits would eat clicks meant for the card.
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}

#if canImport(AppKit)

private struct SupermuxZeronWindowProbeRepresentable: NSViewRepresentable {
    let onMeasure: (CGRect, CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onMeasure = onMeasure
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? ProbeView else { return }
        view.onMeasure = onMeasure
        view.measure()
    }

    final class ProbeView: NSView {
        var onMeasure: ((CGRect, CGRect) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measure()
        }

        override func layout() {
            super.layout()
            measure()
        }

        /// The probe sits at the card's origin at zero size, so the card's own
        /// rect is the probe's origin plus the SwiftUI-reported size — which the
        /// superview's bounds already give us. Both rects are flipped to y-DOWN
        /// so the caller's arithmetic matches `.offset`.
        func measure() {
            guard let window, let content = window.contentView else { return }
            let card = superview ?? self
            let cardInWindow = card.convert(card.bounds, to: nil)
            let contentInWindow = content.convert(content.bounds, to: nil)
            let flippedCard = CGRect(
                x: cardInWindow.minX,
                y: contentInWindow.maxY - cardInWindow.maxY,
                width: cardInWindow.width,
                height: cardInWindow.height
            )
            let flippedContent = CGRect(
                x: contentInWindow.minX,
                y: 0,
                width: contentInWindow.width,
                height: contentInWindow.height
            )
            onMeasure?(flippedCard, flippedContent)
        }
    }
}

#elseif canImport(UIKit)

private struct SupermuxZeronWindowProbeRepresentable: UIViewRepresentable {
    let onMeasure: (CGRect, CGRect) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = ProbeView()
        view.onMeasure = onMeasure
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? ProbeView else { return }
        view.onMeasure = onMeasure
        view.measure()
    }

    final class ProbeView: UIView {
        var onMeasure: ((CGRect, CGRect) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            measure()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        /// UIKit is already y-DOWN, and the clamp is against the window's SAFE
        /// area — an 8 pt margin measured from under a notch is not a margin.
        func measure() {
            guard let window, let card = superview else { return }
            let insets = window.safeAreaInsets
            let safe = window.bounds.inset(by: insets)
            onMeasure?(card.convert(card.bounds, to: window), safe)
        }
    }
}

#endif

// MARK: - Modifier

public extension View {
    /// Anchors a zeron menu card above this trigger, right-aligned, with the
    /// `MENU_IN` entrance and an 8 pt window clamp.
    func supermuxZeronAnchoredMenu<Card: View>(
        isPresented: Binding<Bool>,
        identity: String = "menu",
        pressGuard: SupermuxZeronMenuPressGuard? = nil,
        gap: CGFloat = 6,
        windowMargin: CGFloat = 8,
        @ViewBuilder card: @escaping () -> Card
    ) -> some View {
        modifier(
            SupermuxZeronAnchoredMenu(
                isPresented: isPresented,
                identity: identity,
                pressGuard: pressGuard,
                gap: gap,
                windowMargin: windowMargin,
                card: card
            )
        )
    }
}

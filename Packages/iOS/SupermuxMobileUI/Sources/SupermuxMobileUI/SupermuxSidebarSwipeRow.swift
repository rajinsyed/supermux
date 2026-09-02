import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One swipe action: what it looks like, what it does, and whether committing
/// it is destructive.
struct SupermuxSwipeAction: Identifiable {
    let id: String
    let systemImage: String
    /// Localized title — the VoiceOver label and the accessibility action name.
    let title: String
    let tint: Color
    /// Destructive actions are the only ones a full swipe commits to.
    var isDestructive = false
    let perform: @MainActor () -> Void
}

/// Adds iOS-native trailing swipe actions to a row that is NOT a `List` row.
///
/// The iPhone's workspace list is a UIKit `UITableView` whose Projects section
/// is ONE hosted cell containing this whole SwiftUI subtree (touchpoint #148 —
/// the table's `chromePrefixCount` reorder arithmetic depends on it staying one
/// row). `.swipeActions` exists only on `List` rows, and the table's own native
/// swipe belongs to the cell, which here IS the entire section. So the sidebar's
/// rows would otherwise be the one place in the app without the gesture every
/// other list has.
///
/// **Why a `UIPanGestureRecognizer` and not `DragGesture`.** Only a real
/// recognizer gets a delegate, and the delegate is where the direction gate has
/// to live: `gestureRecognizerShouldBegin` refuses the gesture outright unless
/// the movement is decisively horizontal, so an ordinary vertical flick never
/// starts a reveal. A SwiftUI `DragGesture` can only make that decision AFTER
/// it has already begun tracking, by which point it has taken the touch.
///
/// Behavior matches UIKit's, deliberately:
///
/// - drag left to reveal, release past the halfway point to keep it open;
/// - keep dragging past the commit threshold to fire a destructive action
///   directly, with its button stretching to fill the row as it does;
/// - one row open at a time, arbitrated by the shared ``openRowID`` binding;
/// - tapping anywhere while a row is open closes it instead of activating.
struct SupermuxSidebarSwipeRow<Content: View>: View {
    /// This row's identity in the shared open-row arbitration.
    let rowID: String
    /// The one row currently showing its actions, shared across the section.
    @Binding var openRowID: String?
    let actions: [SupermuxSwipeAction]
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    /// Live pan translation, reset to 0 when the gesture ends (the resting
    /// offset comes from ``isOpen``, so a re-open animates from where it is).
    @State private var dragTranslation: CGFloat = 0
    /// Whether the pan has passed the commit threshold and would fire the
    /// destructive action on release.
    @State private var isCommitting = false

    private static var buttonWidth: CGFloat { 76 }
    /// How far past the revealed tray a drag must go to commit.
    private static var commitThreshold: CGFloat { 148 }

    private var isOpen: Bool { openRowID == rowID }

    private var revealWidth: CGFloat { CGFloat(actions.count) * Self.buttonWidth }

    /// Leftward pull as a positive number, regardless of writing direction.
    private var pull: CGFloat {
        layoutDirection == .rightToLeft ? dragTranslation : -dragTranslation
    }

    /// How far the content is displaced right now: the live pull, rubber-banded
    /// past the tray's width, or the resting open/closed position.
    private var offset: CGFloat {
        let combined = (isOpen ? revealWidth : 0) + pull
        guard combined > revealWidth else { return max(0, combined) }
        // Past the tray the row keeps moving at a third of the finger's speed —
        // the resistance that says you have reached the end.
        return revealWidth + (combined - revealWidth) / 3
    }

    private var directedOffset: CGFloat {
        layoutDirection == .rightToLeft ? offset : -offset
    }

    /// What a full swipe commits to. A row of purely non-destructive actions
    /// never full-swipes.
    private var commitAction: SupermuxSwipeAction? {
        actions.first { $0.isDestructive }
    }

    var body: some View {
        if actions.isEmpty {
            // No actions means no gesture at all — not a row that swipes open
            // onto an empty tray. Callers pass an empty list when the host
            // can't perform the action (e.g. a Mac without workspace close),
            // and a row that moves under the finger but does nothing is worse
            // than one that doesn't move.
            content()
        } else {
            swipeable
        }
    }

    private var swipeable: some View {
        ZStack(alignment: .trailing) {
            actionTray
            content()
                .background(SupermuxSidebarSwipeBackdrop())
                // The tap-to-close shield goes on BEFORE `.offset`, so it
                // travels with the content it covers. Applied after, it would
                // keep the row's original unshifted frame — sitting on top of
                // the revealed tray and swallowing the taps meant for the
                // action buttons, which makes the visible trash button dead
                // and leaves full-swipe as the only way to fire it.
                .overlay {
                    if isOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .offset(x: directedOffset)
        }
        .modifier(SupermuxSidebarSwipePanGesture(
            isOpen: isOpen,
            opensTowardNegativeX: layoutDirection != .rightToLeft,
            onChanged: { translation in
                dragTranslation = translation
                let shouldCommit = commitAction != nil && offset > Self.commitThreshold
                guard shouldCommit != isCommitting else { return }
                isCommitting = shouldCommit
                if shouldCommit { SupermuxHaptics.selection() }
            },
            onEnded: { endDrag() }
        ))
        .animation(reduceMotion ? nil : SupermuxProjectMotion.disclosure, value: isOpen)
        .animation(reduceMotion ? nil : SupermuxProjectMotion.press, value: isCommitting)
        // The revealed buttons are reachable to VoiceOver as row actions; the
        // tray itself is a visual affordance only.
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) {
                    close()
                    action.perform()
                }
            }
        }
    }

    /// The buttons behind the row. While committing, the destructive one
    /// stretches over its siblings — UIKit's full-swipe signature.
    private var actionTray: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    close()
                    action.perform()
                } label: {
                    Image(systemName: action.systemImage)
                        .font(.system(.headline, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(action.tint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: buttonWidth(for: action))
                .accessibilityLabel(action.title)
                .accessibilityIdentifier("SupermuxSwipeAction-\(action.id)-\(rowID)")
            }
        }
        .frame(width: max(revealWidth, offset))
        .clipShape(RoundedRectangle(
            cornerRadius: SupermuxProjectRowMetrics.rowCornerRadius,
            style: .continuous
        ))
        // Nothing to hit while the row is closed, so a stray tap on a
        // zero-width tray can never fire an action.
        .allowsHitTesting(offset > 1)
        .opacity(offset > 1 ? 1 : 0)
    }

    /// The committing action swallows the tray; the others collapse to zero.
    private func buttonWidth(for action: SupermuxSwipeAction) -> CGFloat {
        guard isCommitting, let commit = commitAction else {
            return max(Self.buttonWidth, offset / CGFloat(max(1, actions.count)))
        }
        return action.id == commit.id ? max(revealWidth, offset) : 0
    }

    private func endDrag() {
        let settled = offset
        let committing = isCommitting
        dragTranslation = 0
        isCommitting = false
        if committing, let commit = commitAction {
            openRowID = nil
            commit.perform()
            return
        }
        // Past halfway the tray stays open; short of it the row snaps back —
        // the same threshold UIKit uses.
        openRowID = settled > revealWidth / 2 ? rowID : nil
    }

    private func close() {
        guard isOpen else { return }
        openRowID = nil
    }
}

/// Attaches the horizontal pan (iOS) or nothing at all (macOS, where the
/// section renders in a real `List` and uses native `.swipeActions`).
private struct SupermuxSidebarSwipePanGesture: ViewModifier {
    let isOpen: Bool
    /// Whether a closed row opens on a NEGATIVE x translation (LTR). In RTL
    /// the tray sits on the other side, so the opening drag is rightward.
    let opensTowardNegativeX: Bool
    let onChanged: @MainActor (CGFloat) -> Void
    let onEnded: @MainActor () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(SupermuxRowPanGesture(
            isOpen: isOpen,
            opensTowardNegativeX: opensTowardNegativeX,
            onChanged: onChanged,
            onEnded: onEnded
        ))
        #else
        content
        #endif
    }
}

#if os(iOS)
/// The row's horizontal pan, as a real UIKit recognizer so it can take part in
/// the table's gesture arbitration.
///
/// Deliberately a STOCK `UIPanGestureRecognizer`: `state` is documented as
/// settable only by direct subclasses of `UIGestureRecognizer`
/// (`UIGestureRecognizerSubclass.h`), so a `UIPanGestureRecognizer` subclass
/// must not fail itself. The direction gate belongs in the delegate's
/// `gestureRecognizerShouldBegin(_:)`, which is exactly what it is for.
private struct SupermuxRowPanGesture: UIGestureRecognizerRepresentable {
    let isOpen: Bool
    /// See ``SupermuxSidebarSwipePanGesture/opensTowardNegativeX``.
    let opensTowardNegativeX: Bool
    let onChanged: @MainActor (CGFloat) -> Void
    let onEnded: @MainActor () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        // Cancel the underlying SwiftUI button once the swipe takes over, so a
        // pan never also activates the row it swiped.
        recognizer.cancelsTouchesInView = true
        // Buttons inside the row must still get their touch immediately; only
        // the pan's own recognition is deferred.
        recognizer.delaysTouchesBegan = false
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.gate.isRowOpen = isOpen
        context.coordinator.gate.opensTowardNegativeX = opensTowardNegativeX
        // Re-assert ownership: SwiftUI owns this recognizer's lifetime, and
        // nothing documents that it leaves our delegate installed across
        // updates. Losing the delegate would silently disable the direction
        // gate — the row would start opening on vertical scrolls — so it is
        // cheaper to reinstate it than to depend on undocumented behavior.
        if recognizer.delegate !== context.coordinator {
            recognizer.delegate = context.coordinator
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch recognizer.state {
        case .began, .changed:
            // Second line of defense behind `gestureRecognizerShouldBegin`.
            // SwiftUI owns the recognizer's lifetime and it is not documented
            // whether it keeps the delegate we install, so the direction gate
            // is ALSO enforced here, where nothing external can bypass it. If
            // the delegate ever stopped being consulted, the worst case is a
            // horizontal swipe that also scrolls — never a vertical scroll
            // that drags rows open.
            guard coordinator.tracksHorizontally(recognizer) else { return }
            onChanged(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed:
            let wasTracking = coordinator.isTrackingHorizontally == true
            coordinator.endTracking()
            // Only settle a drag that actually moved the row; otherwise a
            // rejected vertical pan would snap an open row shut mid-scroll.
            if wasTracking { onEnded() }
        default:
            break
        }
    }

    /// Delegate for the direction gate, plus the per-gesture direction latch.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The pure direction logic, configured from the row each update.
        var gate = SupermuxSwipeDirectionGate()

        /// Whether the pan may move the row, deciding once per gesture.
        func tracksHorizontally(_ pan: UIPanGestureRecognizer) -> Bool {
            gate.tracks(translation: pan.translation(in: pan.view))
        }

        var isTrackingHorizontally: Bool? { gate.verdict }

        func endTracking() {
            gate.reset()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            return gate.mayBegin(translation: pan.translation(in: pan.view))
        }

        /// Coexist with the table's scroll pan rather than outranking it.
        ///
        /// The tempting alternative — a failure requirement making the table's
        /// pan wait for this one — is wrong here, and the difference is about
        /// what each recognizer fails ON. The app's existing swipe-back gate
        /// (`InteractiveSwipeBackEnabler`) already subordinates scrolling to a
        /// screen-edge recognizer, and that costs nothing because an edge
        /// recognizer fails on touch-down LOCATION: an off-edge touch resolves
        /// instantly. A direction-discriminating pan can only fail once the
        /// finger has moved far enough to classify, so putting one ahead of the
        /// table's pan would delay the start of every vertical scroll in the
        /// list to buy a gesture used far more rarely.
        ///
        /// Recognizing simultaneously costs nothing instead, because
        /// ``gestureRecognizerShouldBegin`` has already refused every drag that
        /// is not decisively horizontal — so in practice the two never both
        /// track the same touch.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif

/// The opaque plate a swiped row slides over.
///
/// Without it the action buttons show THROUGH the row content, because the
/// hosting table cell's background is clear. `UIColor.systemBackground` tracks
/// light/dark and the list's own backing exactly.
private struct SupermuxSidebarSwipeBackdrop: View {
    var body: some View {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color.clear
        #endif
    }
}

// The predicate below is pure. Only the UIKit observer needs SwiftUI, and it
// does not exist on macOS — so both imports are scoped to the platform that
// actually has it, keeping the macOS build free of unused public imports.
#if canImport(UIKit) && !os(macOS)
public import SwiftUI
public import UIKit
#endif

/// Whether the compact (phone) workspace shell should be showing its ROOT
/// chrome — the list's navigation-bar items, the tab bar, and the compose
/// button — right now.
///
/// **Why this is not just `path.isEmpty`.** The two ways back from a pushed
/// workspace update that path at opposite ends of the transition:
///
/// - Tapping the back button runs `compactNavigationPath.removeLast()` first,
///   so SwiftUI has already restored the root chrome by the time the pop
///   animates.
/// - The UIKit edge-swipe runs the other way round. It reveals the root
///   controller immediately and `NavigationStack` only writes the emptied path
///   back once the gesture commits. Anything gated on `path.isEmpty` therefore
///   stays hidden for the whole swipe and visibly pops in a beat later.
///
/// Folding an in-flight interactive pop into the predicate closes that gap
/// without loosening the steady state: sitting on a pushed workspace still
/// reports `false`, so root items cannot leak into the detail's toolbar (the
/// regression `664a54dd13` fixed) and the tab bar stays hidden over the
/// terminal.
///
/// The tab bar has a second, separate reason to lag, which the same predicate
/// fixes: the `.toolbarVisibility(.hidden, for: .tabBar)` request lives on the
/// pushed destination, and that destination stays mounted — still asking for a
/// hidden bar — for the entire pop animation. Feeding it this predicate instead
/// of a constant lets the outgoing detail un-hide the bar as the pop starts.
public struct SupermuxCompactRootChrome: Equatable, Sendable {
    /// True between an interactive pop beginning and it being rolled back.
    /// A *committed* pop deliberately leaves this set: clearing it mid-animation
    /// would re-hide the chrome the gesture just revealed. ``navigationPathChanged()``
    /// clears it once the emptied path has taken over.
    public private(set) var interactivePopRevealsRoot = false

    public init() {}

    /// - Parameter pathIsEmpty: Whether the compact navigation path is empty.
    public func isVisible(pathIsEmpty: Bool) -> Bool {
        pathIsEmpty || interactivePopRevealsRoot
    }

    /// The edge-swipe started dragging the root back into view.
    public mutating func interactivePopBegan() {
        interactivePopRevealsRoot = true
    }

    /// The edge-swipe was released short of the commit threshold and UIKit
    /// animated the detail back. The root is not being revealed after all.
    public mutating func interactivePopRolledBack() {
        interactivePopRevealsRoot = false
    }

    /// The navigation path changed, so it is authoritative again. Clearing here
    /// is what stops a completed swipe from leaking root chrome onto the NEXT
    /// pushed workspace: the push writes a non-empty path, which lands here.
    public mutating func navigationPathChanged() {
        interactivePopRevealsRoot = false
    }
}

#if canImport(UIKit) && !os(macOS)
/// Reports the interactive (edge-swipe) back gesture to SwiftUI while it is
/// still in flight, so ``SupermuxCompactRootChrome`` can un-hide the root
/// chrome at the start of the swipe rather than after it.
///
/// This only *observes*. The pop gesture's delegate — which decides whether the
/// gesture may begin at all, and how it arbitrates against the terminal's pans
/// — stays with upstream's `InteractiveSwipeBackEnabler`; a target-action is
/// additive and does not disturb it.
public struct SupermuxInteractivePopObserver: UIViewControllerRepresentable {
    /// `true` as the gesture begins revealing the root; `false` only when the
    /// interactive pop is rolled back.
    private let report: @MainActor (Bool) -> Void

    public init(report: @escaping @MainActor (Bool) -> Void) {
        self.report = report
    }

    public func makeUIViewController(context: Context) -> ObserverController {
        let controller = ObserverController()
        controller.report = report
        return controller
    }

    public func updateUIViewController(_ uiViewController: ObserverController, context: Context) {
        uiViewController.report = report
    }

    public final class ObserverController: UIViewController {
        var report: (@MainActor (Bool) -> Void)?

        public override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let gesture = navigationController?.interactivePopGestureRecognizer else {
                return
            }
            // Re-parenting calls this again; drop the previous registration so
            // one gesture cannot report twice.
            gesture.removeTarget(self, action: nil)
            gesture.addTarget(self, action: #selector(popGestureChanged(_:)))
        }

        @objc private func popGestureChanged(_ gesture: UIGestureRecognizer) {
            switch gesture.state {
            case .began:
                report?(true)
            case .ended, .cancelled, .failed:
                // The finger lifts before the transition finishes: UIKit either
                // completes the pop or animates the detail back. Only the
                // rollback has to be reported — a completed pop hands over to
                // the emptied navigation path.
                guard let coordinator = navigationController?.transitionCoordinator else {
                    report?(false)
                    return
                }
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    guard context.isCancelled else { return }
                    self?.report?(false)
                }
            default:
                break
            }
        }
    }
}
#endif

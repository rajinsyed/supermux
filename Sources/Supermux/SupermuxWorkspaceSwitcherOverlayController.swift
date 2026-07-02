import AppKit
import CmuxAppKitSupportUI
import SupermuxKit
import SwiftUI

/// Installs and tears down the workspace switcher's SwiftUI overlay inside a
/// window's content hierarchy.
///
/// It deliberately mirrors cmux's command palette overlay shape — a transparent
/// container view hosting an `NSHostingView`, pinned with Auto Layout to the
/// install target's `reference` (content) view, mounted above the window's
/// portal-hosted terminals/browsers — rather than an `NSPanel`. A panel would
/// take key/focus and risk window-level/Space issues; an attached overlay keeps
/// the main window key, so the app-local event monitor still sees the held-Cmd
/// release that commits the switch. The install target is resolved on each
/// presentation and reused when unchanged.
@MainActor
final class SupermuxWorkspaceSwitcherOverlayController {
    /// The observable state the controller mutates while the switcher is up.
    let viewState = SupermuxWorkspaceSwitcherViewState()

    /// The shared project-logo cache the hosted view renders card badges from.
    private let iconStore: SupermuxProjectIconStore

    private let containerView = ContainerView()
    private var hostingView: NSHostingView<SupermuxWorkspaceSwitcherView>?
    private weak var installedContainer: NSView?
    private weak var installedReference: NSView?
    private var installConstraints: [NSLayoutConstraint] = []

    /// Creates the overlay controller.
    /// - Parameter iconStore: Shared, pre-warmed project-logo cache (owned by
    ///   the composition root) handed to the hosted SwiftUI view.
    init(iconStore: SupermuxProjectIconStore) {
        self.iconStore = iconStore
    }

    /// Whether the overlay is currently mounted in a window.
    var isShown: Bool { containerView.superview != nil }

    /// Mounts the overlay in `window`, installing the view hierarchy on first use
    /// and re-pinning it if the resolved target changed (e.g. glass effect toggled).
    func show(in window: NSWindow) {
        guard let target = installationTarget(for: window) else { return }
        ensureHostingInstalled()

        if containerView.superview !== target.container || installedReference !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            containerView.translatesAutoresizingMaskIntoConstraints = false
            target.container.addSubview(containerView, positioned: .above, relativeTo: nil)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: target.reference.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainer = target.container
            installedReference = target.reference
        } else {
            // Already pinned in the same place — just promote above siblings.
            target.container.addSubview(containerView, positioned: .above, relativeTo: nil)
        }
    }

    /// Removes the overlay from the window (view state is retained for reuse).
    /// The install pins are torn down: an active constraint holds strong
    /// references to its anchor items, which would otherwise keep a closed
    /// window's content hierarchy alive until the next show.
    func hide() {
        containerView.removeFromSuperview()
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        installedContainer = nil
        installedReference = nil
    }

    private func ensureHostingInstalled() {
        guard hostingView == nil else { return }
        let hosting = NSHostingView(
            rootView: SupermuxWorkspaceSwitcherView(state: viewState, iconStore: iconStore)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: containerView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        hostingView = hosting
    }

    /// Resolves the glass-effect foreground container when present (so the
    /// overlay floats above portal-hosted terminals/browsers), else the window's
    /// theme frame over its content view.
    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        // Upstream moved WindowGlassEffect into CmuxAppKitSupportUI and made
        // portalInstallationTarget an instance method returning a struct (was a
        // static returning a tuple). The lookup reads window-scoped associated
        // objects, so a fresh instance resolves the same target.
        if let glassTarget = WindowGlassEffect().portalInstallationTarget(for: window) {
            return (container: glassTarget.container, reference: glassTarget.reference)
        }
        guard let contentView = window.contentView, let themeFrame = contentView.superview else {
            return nil
        }
        return (themeFrame, contentView)
    }

    /// A transparent container that hosts the overlay; it captures clicks (so card
    /// taps and tap-to-cancel work) while the switcher is up, including the first
    /// click while ⌘ is held.
    private final class ContainerView: NSView {
        override var isOpaque: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

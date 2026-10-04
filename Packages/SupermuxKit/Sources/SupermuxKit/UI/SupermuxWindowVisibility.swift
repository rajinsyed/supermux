import AppKit
public import Combine
public import SwiftUI

/// Whether the window hosting a view is actually on screen, so a mounted view
/// can pause background work (git status and fetches, PR and usage polling)
/// that nobody can see.
///
/// On screen means: ordered in, not minimized, not fully covered by other
/// windows or on another Space (`occlusionState`, or the key window), and the
/// app not hidden. A Remote Host Mode window is ordered out, so a headless
/// host reads as off screen too.
///
/// Coming on screen is reported at once; going off screen only once the
/// window has stayed off screen for ``hideDelay``, so a brief cover (a Space
/// swipe, a window dragged across) never stops and restarts the work.
///
/// Attach with `supermuxTracksWindowVisibility(_:)`; own the object with
/// `@StateObject` so it lives as long as the mount.
@MainActor
public final class SupermuxWindowVisibility: ObservableObject {
    /// Whether the tracked window is on screen. `true` until the view reaches
    /// a window, so a fresh mount behaves as it did before this existed.
    @Published public private(set) var isOnScreen = true

    /// How long the window must stay off screen before ``isOnScreen`` turns false.
    public let hideDelay: Duration

    private weak var window: NSWindow?
    private var pendingHide: Task<Void, Never>?

    /// Creates the observer.
    /// - Parameter hideDelay: How long the window must stay off screen before
    ///   it is reported hidden; defaults to 10 seconds.
    public init(hideDelay: Duration = .seconds(10)) {
        self.hideDelay = hideDelay
    }

    deinit {
        pendingHide?.cancel()
    }

    /// Re-reads the visibility of `window` (the probe's window, `nil` when the
    /// probe left its window).
    func update(window: NSWindow?) {
        self.window = window
        if Self.windowIsOnScreen(window) {
            pendingHide?.cancel()
            pendingHide = nil
            if !isOnScreen { isOnScreen = true }
            return
        }
        guard isOnScreen, pendingHide == nil else { return }
        pendingHide = Task { [weak self, hideDelay] in
            do {
                try await Task.sleep(for: hideDelay)
            } catch {
                return
            }
            guard let self else { return }
            self.pendingHide = nil
            // Look again rather than trusting the notification that started
            // the wait: the window may be back without one we observe.
            if !Self.windowIsOnScreen(self.window) { self.isOnScreen = false }
        }
    }

    /// Windows whose occlusion state has reported `.visible` at least once.
    /// Weak, so a closed window drops out on its own.
    private static let windowsThatReportedVisible = NSHashTable<NSWindow>.weakObjects()

    /// The same rule as cmux's `TerminalRendererWindowVisibility`, plus the
    /// app not hidden. `occlusionState` decides on a real display (covered or
    /// on another Space drops `.visible`), but a virtual or headless display
    /// never raises `.visible` for a window that is ordered in and drawing, so
    /// until a window has reported it once its ordinary on-screen state is
    /// trusted instead. A key window always counts as on screen. Every
    /// Supermux "is this window on screen" gate uses this one rule.
    public static func windowIsOnScreen(_ window: NSWindow?) -> Bool {
        guard let window, !NSApplication.shared.isHidden,
              window.isVisible, !window.isMiniaturized else { return false }
        if window.occlusionState.contains(.visible) {
            windowsThatReportedVisible.add(window)
            return true
        }
        if window.isKeyWindow { return true }
        // Occlusion has been trustworthy for this window: honor its verdict.
        if windowsThatReportedVisible.contains(window) { return false }
        return window.isOnActiveSpace
    }
}

extension View {
    /// Keeps `visibility` following the window this view is in, through an
    /// empty, non-interactive probe view behind this one.
    public func supermuxTracksWindowVisibility(_ visibility: SupermuxWindowVisibility) -> some View {
        background(SupermuxWindowVisibilityProbe(visibility: visibility))
    }
}

private struct SupermuxWindowVisibilityProbe: NSViewRepresentable {
    let visibility: SupermuxWindowVisibility

    func makeNSView(context: Context) -> SupermuxWindowVisibilityProbeView {
        let view = SupermuxWindowVisibilityProbeView(frame: .zero)
        view.visibility = visibility
        return view
    }

    func updateNSView(_ view: SupermuxWindowVisibilityProbeView, context: Context) {
        guard view.visibility !== visibility else { return }
        view.visibility = visibility
        visibility.update(window: view.window)
    }
}

/// Watches its window's occlusion, key, minimize and close notifications and
/// the app's hide/unhide, and reports each to the ``SupermuxWindowVisibility``.
private final class SupermuxWindowVisibilityProbeView: NSView {
    weak var visibility: SupermuxWindowVisibility?

    private static let windowNotifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.willCloseNotification,
    ]

    private static let applicationNotifications: [Notification.Name] = [
        NSApplication.didHideNotification,
        NSApplication.didUnhideNotification,
    ]

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let newWindow else { return }
        for name in Self.windowNotifications {
            center.addObserver(self, selector: #selector(visibilityMayHaveChanged), name: name, object: newWindow)
        }
        for name in Self.applicationNotifications {
            center.addObserver(self, selector: #selector(visibilityMayHaveChanged), name: name, object: nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility?.update(window: window)
    }

    @objc private func visibilityMayHaveChanged(_ notification: Notification) {
        // A closing window is going away, whatever its state still says.
        if notification.name == NSWindow.willCloseNotification {
            visibility?.update(window: nil)
        } else {
            visibility?.update(window: window)
        }
    }
}

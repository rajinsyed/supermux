import AppKit
import CmuxSettingsUI
import Foundation

/// SUPERMUX — Remote Host Mode: a Mac used only as a remote host for the
/// iPhone app or another Mac runs with no window on screen and no Dock icon,
/// while every workspace and terminal keeps running.
///
/// Windows are only ever HIDDEN (`orderOut`), never closed: a main window owns
/// its workspaces (its `TabManager`), and closing it would close them.
///
/// - The setting (``SupermuxRemoteHostModeSetting``, Settings › App) turns the
///   mode on: every main window hides, the activation policy becomes
///   `.accessory` (Menu Bar Only's mechanism) and the menu bar item gains
///   Show/Hide Supermux and Turn Off Remote Host Mode
///   (``SupermuxRemoteHostModeMenuItems``). Off shows the windows again.
/// - "Headless" is the mode on with no main window on screen. While headless,
///   a new main window (session restore at launch, a window a device's new
///   workspace needs) stays hidden, and a focus request (a socket or device
///   command, launch) neither shows a window nor activates the app. Only the
///   user's own show requests (the menu bar item, reopening the app) do.
/// - While the mode is on, a main window's close button and Close Window hide
///   that window instead of closing it.
///
/// Hooks (SUPERMUX-TOUCHPOINTS.md #830–#833): `AppDelegate` (settings sync,
/// new windows, close, reopen), `MainWindowVisibilityController` (focus),
/// `MenuBarExtraController` (policy, menu bar item), `AppSection` (the row).
@MainActor
final class SupermuxRemoteHostMode {
    static let shared = SupermuxRemoteHostMode()

    /// The value last applied, so a defaults change acts only on a real flip.
    /// `nil` until the first sync at launch, which records without acting
    /// (windows created at launch already obey the mode).
    private var appliedEnabled: Bool?

    // MARK: - Setting

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: SupermuxRemoteHostModeSetting.key.userDefaultsKey)
    }

    nonisolated static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: SupermuxRemoteHostModeSetting.key.userDefaultsKey)
    }

    /// The mode on with no main window on screen.
    var isHeadless: Bool {
        Self.isEnabled() && visibleMainWindows().isEmpty
    }

    // MARK: - Hooks

    /// `syncApplicationPresentationPreferences` (every defaults change): hides
    /// every main window when the mode turns on, shows them when it turns off.
    func syncToSettings() {
        let enabled = Self.isEnabled()
        defer { appliedEnabled = enabled }
        guard let applied = appliedEnabled, applied != enabled else { return }
        if enabled {
            hideAllWindows()
        } else {
            showAllWindows(activate: false)
        }
    }

    /// `createMainWindow`: a new main window stays hidden while headless.
    func keepsNewMainWindowHidden() -> Bool {
        isHeadless
    }

    /// `MainWindowVisibilityController.focus`: while headless only the user's
    /// own show requests may show a window or activate the app.
    func blocksWindowFocus(reason: MainWindowVisibilityController.Reason) -> Bool {
        guard isHeadless else { return false }
        switch reason {
        case .menuBar, .globalHotkey, .applicationReopen:
            return false
        default:
            return true
        }
    }

    /// The close button, ⌘W on an empty window and Close Window: while the
    /// mode is on the window hides and keeps its workspaces. Returns whether
    /// it handled the close. A quit still closes windows as usual.
    func hidesInsteadOfClosing(_ window: NSWindow, isTerminating: Bool) -> Bool {
        guard Self.isEnabled(), !isTerminating else { return false }
        hide([window])
        return true
    }

    /// Reopening the app (Finder, Spotlight, `open`) while headless shows it.
    func showsWindowsOnReopen() -> Bool {
        guard isHeadless else { return false }
        showAllWindows(activate: true)
        return true
    }

    // MARK: - Actions (menu bar item, settings sync, socket drivers)

    /// Shows every main window ("Show Supermux"); `activate` brings the app forward.
    func showAllWindows(activate: Bool) {
        guard let app = AppDelegate.shared else { return }
        var windows = app.mainWindowsForVisibilityController()
        if windows.isEmpty, let window = app.windowForMainWindowId(app.ensureInitialMainWindowIfNeeded(shouldActivate: false)) {
            windows = [window]
        }
        guard !windows.isEmpty else { return }
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        _ = app.mainWindowVisibilityController.reveal(
            windows,
            preferredWindow: nil,
            reason: .menuBar,
            activation: activate ? .runningApplication([.activateAllWindows]) : .none,
            makeKey: activate
        )
    }

    /// Hides every main window ("Hide Supermux", the mode turning on).
    func hideAllWindows() {
        guard let app = AppDelegate.shared else { return }
        hide(app.mainWindowsForVisibilityController())
    }

    /// "Turn Off Remote Host Mode": the setting off, the windows shown.
    func turnOff(activate: Bool) {
        appliedEnabled = false
        Self.setEnabled(false)
        showAllWindows(activate: activate)
    }

    // MARK: - Window state

    func visibleMainWindows() -> [NSWindow] {
        guard let app = AppDelegate.shared else { return [] }
        return app.mainWindowsForVisibilityController().filter(Self.isOnScreen)
    }

    static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.alphaValue > 0.001
    }

    private func hide(_ windows: [NSWindow]) {
        guard !windows.isEmpty else { return }
        for window in windows {
            window.orderOut(nil)
        }
        // A window the user dismissed earlier must not come back on the next
        // activation (opening Settings from the menu bar item).
        if let controller = AppDelegate.shared?.mainWindowVisibilityController {
            controller.dismissedWindowRestoreTargets.removeAll { target in windows.contains { $0 === target } }
            controller.appHiddenWindowRestoreTargets.removeAll { target in windows.contains { $0 === target } }
        }
        // Hand the keyboard back to the app the user was in, unless another of
        // this app's windows (Settings) is still open.
        if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApp.hide(nil)
        }
    }
}

#if DEBUG
import AppKit
import Foundation
import UserNotifications

/// `supermux.devices.remote_host.*` (DEBUG builds only): E2E drivers for
/// Remote Host Mode (`tests/supermux/loopback_remote_host_mode_e2e.py`),
/// routed from ``SupermuxDevicesSocketCommands``. Each drives the user's own
/// path: the setting's defaults key, the menu bar item's actions, a window's
/// close button and Close Window.
///
/// - `remote_host.state {}` — `enabled`, `headless`, `activation_policy`
///   (`regular` / `accessory` / `prohibited`), `app_active`, `app_hidden`,
///   `menu_bar_item_installed`, `menu_items` (`[{action, title}]`, as the
///   menu bar item shows them now) and `main_windows`
///   (`[{window_id, visible, key, miniaturized}]`, hidden ones included).
/// - `remote_host.set {enabled}` — writes the setting as the Settings toggle
///   does; the app applies it from its defaults observer (poll `state`).
/// - `remote_host.menu {action: show|hide|turn_off, activate?}` — a click on
///   that menu bar item; `activate: false` keeps the app in the background.
/// - `remote_host.close_window {window_id, via: close_button|close_window_command}`
///   — the window's close button (`performClose`) or Close Window
///   (`closeWindowWithConfirmation`); `dialog_shown` says whether Close
///   Window would have asked first.
/// - `remote_host.global_hotkey {}` — a press of the global show/hide hotkey
///   (`toggleApplicationVisibilityFromGlobalHotkey`).
/// - `remote_host.notification_click {workspace_id, surface_id?}` — a click on
///   a delivered terminal notification's banner for that terminal (its default
///   action, as the notification center delegate hands it over).
///
/// Both run inside a socket command, which keeps the app in the background
/// (``TerminalController/shouldSuppressSocketCommandActivation()``).
@MainActor
enum SupermuxRemoteHostSocketCommands {
    static let methodPrefix = "remote_host."

    static func handles(_ name: String) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle(_ name: String, _ params: [String: Any]) throws -> [String: Any] {
        switch name.dropFirst(methodPrefix.count) {
        case "state":
            return state()
        case "set":
            guard let enabled = params["enabled"] as? Bool else { throw SupermuxMirrorSocketCommands.InvalidParams(message: "enabled must be a boolean") }
            // The app's defaults observer applies it, as for the Settings toggle; callers poll `state`.
            SupermuxRemoteHostMode.setEnabled(enabled)
            return state()
        case "menu":
            guard let raw = params["action"] as? String, let action = SupermuxRemoteHostModeMenuItems.Action(rawValue: raw) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "action must be show, hide or turn_off")
            }
            menuItems().perform(action, activate: params["activate"] as? Bool ?? true)
            return state()
        case "close_window":
            return try closeWindow(params)
        case "global_hotkey":
            AppDelegate.shared?.toggleApplicationVisibilityFromGlobalHotkey()
            return state()
        case "notification_click":
            return try notificationClick(params)
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "unknown remote_host method \(name)")
        }
    }

    private static func menuItems() -> SupermuxRemoteHostModeMenuItems {
        AppDelegate.shared?.menuBarExtraController?.supermuxRemoteHostItems ?? SupermuxRemoteHostModeMenuItems()
    }

    private static func state() -> [String: Any] {
        let app = AppDelegate.shared
        let windows = app?.mainWindowsForVisibilityController() ?? []
        return [
            "enabled": SupermuxRemoteHostMode.isEnabled(),
            "headless": SupermuxRemoteHostMode.shared.isHeadless,
            "activation_policy": policyName(NSApp.activationPolicy()),
            "app_active": NSApp.isActive,
            "app_hidden": NSApp.isHidden,
            "menu_bar_item_installed": app?.menuBarExtraController != nil,
            "menu_items": menuItems().visibleActions().map { action -> [String: Any] in
                ["action": action.rawValue, "title": SupermuxRemoteHostModeMenuItems.title(for: action)]
            },
            "main_windows": windows.map { window -> [String: Any] in
                [
                    "window_id": app?.mainWindowId(from: window)?.uuidString ?? NSNull(),
                    "visible": SupermuxRemoteHostMode.isOnScreen(window),
                    "key": window.isKeyWindow,
                    "miniaturized": window.isMiniaturized,
                ]
            },
        ]
    }

    private static func closeWindow(_ params: [String: Any]) throws -> [String: Any] {
        guard let app = AppDelegate.shared,
              let raw = params["window_id"] as? String, let id = UUID(uuidString: raw),
              let window = app.windowForMainWindowId(id) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "window_id must name a main window")
        }
        var dialogShown = false
        switch params["via"] as? String {
        case "close_button":
            window.performClose(nil)
        case "close_window_command":
            app.debugCloseMainWindowConfirmationHandler = { _ in
                dialogShown = true
                return false
            }
            defer { app.debugCloseMainWindowConfirmationHandler = nil }
            _ = app.closeWindowWithConfirmation(window)
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "via must be close_button or close_window_command")
        }
        var result = state()
        result["dialog_shown"] = dialogShown
        return result
    }

    private static func notificationClick(_ params: [String: Any]) throws -> [String: Any] {
        guard let app = AppDelegate.shared,
              let raw = params["workspace_id"] as? String, let workspaceID = UUID(uuidString: raw) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "workspace_id must name a workspace")
        }
        let surfaceID = (params["surface_id"] as? String).flatMap(UUID.init(uuidString:))
        // What the notification center delegate does for a banner click (#880), then the open.
        SupermuxRemoteHostMode.shared.notificationClicked(actionIdentifier: UNNotificationDefaultActionIdentifier)
        let opened = app.openNotification(tabId: workspaceID, surfaceId: surfaceID, notificationId: nil)
        var result = state()
        result["opened"] = opened
        return result
    }

    private static func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}
#endif

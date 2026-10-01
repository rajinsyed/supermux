import AppKit
import Foundation

/// The "Close “X”?" prompt for closing device mirrors: **Close on <Mac>**
/// (destructive), **Hide Here**, **Cancel**. One prompt covers any number of
/// mirrors (a multi-close asks once). Cancel is the safe default: Return and
/// Esc both answer it, so no key press closes anything on another Mac. The
/// text names the Mac once and says what each answer does. When every
/// involved Mac is offline, closing there is impossible, so that button is
/// disabled.
@MainActor
enum SupermuxDeviceMirrorClosePrompt {
    struct Item {
        let title: String
        let deviceName: String
        let isConnected: Bool
    }

    /// Guards against a second prompt while one is up. Deliberately neither
    /// `TabManager.beginCloseConfirmationSession()` nor its in-flight flag:
    /// that session ends a runloop turn late, so upstream's batch "Close
    /// workspaces?" prompt (which follows this one synchronously in a mixed
    /// multi-close) would silently cancel the batch, and this prompt would
    /// refuse to follow upstream's "Close pinned workspace?" one.
    private static var isPresenting = false

    static func ask(_ items: [Item], in manager: TabManager) -> SupermuxDeviceMirrorCloser.Decision {
        guard !items.isEmpty, !isPresenting else { return .cancel }
        isPresenting = true
        defer { isPresenting = false }
        let alert = makeAlert(items)
        // Return already answers Cancel (its key equivalent); a button holds one
        // key equivalent, so Esc is routed to the same button here.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == escapeKeyCode, event.window === alert.window else { return event }
            escapeButton(of: alert)?.performClick(nil)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        switch alert.runCmuxModal(presentingWindow: manager.window) {
        case .alertFirstButtonReturn: return .closeOnMac
        case .alertSecondButtonReturn: return .hideHere
        default: return .cancel
        }
    }

    /// What the prompt for `items` shows, built but never presented (the
    /// `supermux.devices.close_prompt` socket method): its text, and per
    /// button the role, title, key equivalent, destructive flag, enablement,
    /// hidden flag and alpha, plus which button Esc answers.
    static func describe(_ items: [Item]) -> [String: Any] {
        let alert = makeAlert(items)
        let roles = Array(zip(buttonRoles, alert.buttons))
        let escape = escapeButton(of: alert)
        return [
            "message_text": alert.messageText,
            "informative_text": alert.informativeText,
            "buttons": roles.map { role, button -> [String: Any] in
                [
                    "role": role,
                    "title": button.title,
                    "key_equivalent": button.keyEquivalent,
                    "destructive": button.hasDestructiveAction,
                    "enabled": button.isEnabled,
                    "hidden": button.isHidden,
                    "alpha": Double(button.alphaValue),
                ]
            },
            "escape_role": roles.first { $0.1 === escape }?.0 ?? NSNull(),
        ]
    }

    /// The roles of the alert's buttons, in the order they are added.
    private static let buttonRoles = ["close_on_mac", "hide", "cancel"]
    /// `kVK_Escape`.
    private static let escapeKeyCode: UInt16 = 53

    /// The button Esc presses: Cancel, the last one added.
    private static func escapeButton(of alert: NSAlert) -> NSButton? {
        alert.buttons.last
    }

    private static func makeAlert(_ items: [Item]) -> NSAlert {
        let deviceNames = orderedUnique(items.map(\.deviceName))
        let anyConnected = items.contains(where: \.isConnected)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title(items, deviceNames: deviceNames)
        alert.informativeText = message(items, deviceNames: deviceNames, anyConnected: anyConnected)
        let close = alert.addButton(withTitle: closeTitle(deviceNames))
        let hide = alert.addButton(withTitle: String(localized: "supermux.devices.close.button.hideHere", defaultValue: "Hide Here"))
        let cancel = alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        close.hasDestructiveAction = true
        close.isEnabled = anyConnected
        close.keyEquivalent = ""
        hide.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.window.initialFirstResponder = cancel
        return alert
    }

    /// "Close “X”?", or the count for several (naming no Mac: the message does).
    private static func title(_ items: [Item], deviceNames: [String]) -> String {
        if items.count == 1, let item = items.first {
            return String(
                format: String(localized: "supermux.devices.close.prompt.title", defaultValue: "Close “%@”?"),
                locale: .current, item.title
            )
        }
        let format = deviceNames.count == 1
            ? String(localized: "supermux.devices.close.prompt.multiTitle", defaultValue: "Close %lld workspaces?")
            : String(localized: "supermux.devices.close.multi.title", defaultValue: "Close %lld workspaces on other Macs?")
        return String(format: format, locale: .current, Int64(items.count))
    }

    /// What Close on <Mac> does and what stays, what Hide Here does, the
    /// workspaces of a multi-close on several Macs, and why Close is off
    /// while the Mac is offline. The Mac is named once, in the first line.
    private static func message(_ items: [Item], deviceNames: [String], anyConnected: Bool) -> String {
        let single = items.count == 1
        var paragraphs: [String] = []
        if deviceNames.count == 1 {
            let format = single
                ? String(
                    localized: "supermux.devices.close.prompt.message",
                    defaultValue: "This closes the workspace and its terminals on %@. Its files, worktree and branch stay."
                )
                : String(
                    localized: "supermux.devices.close.prompt.multiMessage",
                    defaultValue: "This closes the workspaces and their terminals on %@. Their files, worktrees and branches stay."
                )
            paragraphs.append(String(format: format, locale: .current, deviceNames[0]))
        } else {
            paragraphs.append(String(
                localized: "supermux.devices.close.prompt.multiMessageMacs",
                defaultValue: "This closes the workspaces and their terminals on the Macs they run on. Their files, worktrees and branches stay."
            ))
        }
        paragraphs.append(single
            ? String(
                localized: "supermux.devices.close.prompt.hideHint",
                defaultValue: "Hide Here keeps it running there and only removes it from this Mac's sidebar."
            )
            : String(
                localized: "supermux.devices.close.prompt.multiHideHint",
                defaultValue: "Hide Here keeps them running there and only removes them from this Mac's sidebar."
            ))
        if deviceNames.count > 1 {
            paragraphs.append(items.map { "• \($0.title) (\($0.deviceName))" }.joined(separator: "\n"))
        } else if !single {
            paragraphs.append(items.map { "• \($0.title)" }.joined(separator: "\n"))
        }
        if !anyConnected {
            paragraphs.append(deviceNames.count == 1
                ? String(
                    localized: "supermux.devices.close.prompt.offline",
                    defaultValue: "That Mac is offline right now, so you can only hide the workspace here."
                )
                : String(
                    localized: "supermux.devices.close.prompt.offlineMulti",
                    defaultValue: "Those Macs are offline right now, so you can only hide the workspaces here."
                ))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func closeTitle(_ deviceNames: [String]) -> String {
        deviceNames.count == 1
            ? String(
                format: String(localized: "supermux.devices.close.button.closeOnMac", defaultValue: "Close on %@"),
                locale: .current, deviceNames[0]
            )
            : String(localized: "supermux.devices.close.button.closeOnMacs", defaultValue: "Close on Their Macs")
    }

    private static func orderedUnique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

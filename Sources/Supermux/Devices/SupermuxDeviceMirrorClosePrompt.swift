import AppKit
import Foundation

/// The "Close on <Mac>?" prompt for closing device mirrors: **Close on <Mac>**,
/// **Hide Here**, **Cancel**. One prompt covers any number of mirrors (a
/// multi-close asks once). When every involved Mac is offline, closing there
/// is impossible, so that button is disabled and Hide Here is the default.
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
        switch alert.runCmuxModal(presentingWindow: manager.window) {
        case .alertFirstButtonReturn: return .closeOnMac
        case .alertSecondButtonReturn: return .hideHere
        default: return .cancel
        }
    }

    private static func makeAlert(_ items: [Item]) -> NSAlert {
        let deviceNames = orderedUnique(items.map(\.deviceName))
        let anyConnected = items.contains(where: \.isConnected)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if items.count == 1, let item = items.first {
            alert.messageText = String(
                format: String(localized: "supermux.devices.close.single.title", defaultValue: "Close “%@” on %@?"),
                locale: .current, item.title, item.deviceName
            )
            alert.informativeText = String(
                format: String(
                    localized: "supermux.devices.close.single.message",
                    defaultValue: "This workspace runs on %@. Close it there, or hide it from this Mac only (it keeps running there)."
                ),
                locale: .current, item.deviceName
            )
        } else {
            alert.messageText = String(
                format: String(localized: "supermux.devices.close.multi.title", defaultValue: "Close %lld workspaces on other Macs?"),
                locale: .current, Int64(items.count)
            )
            let lines = items.map { "• \($0.title) (\($0.deviceName))" }.joined(separator: "\n")
            alert.informativeText = String(
                format: String(
                    localized: "supermux.devices.close.multi.message",
                    defaultValue: "These workspaces run on other Macs. Close them there, or hide them from this Mac only (they keep running there).\n%@"
                ),
                locale: .current, lines
            )
        }
        if !anyConnected {
            alert.informativeText += "\n\n" + String(
                format: String(
                    localized: "supermux.devices.close.offline",
                    defaultValue: "%@ is offline right now, so the workspace can only be hidden here."
                ),
                locale: .current, deviceNames.joined(separator: ", ")
            )
        }
        let closeTitle = deviceNames.count == 1
            ? String(
                format: String(localized: "supermux.devices.close.button.closeOnMac", defaultValue: "Close on %@"),
                locale: .current, deviceNames[0]
            )
            : String(localized: "supermux.devices.close.button.closeOnMacs", defaultValue: "Close on Their Macs")
        let close = alert.addButton(withTitle: closeTitle)
        let hide = alert.addButton(withTitle: String(localized: "supermux.devices.close.button.hideHere", defaultValue: "Hide Here"))
        let cancel = alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        if anyConnected {
            close.keyEquivalent = "\r"
            hide.keyEquivalent = ""
        } else {
            close.isEnabled = false
            close.keyEquivalent = ""
            hide.keyEquivalent = "\r"
        }
        return alert
    }

    private static func orderedUnique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

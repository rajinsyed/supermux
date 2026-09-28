import AppKit
import CmuxSurfaceCatalogModel
import Foundation

/// The "New Workspace on ▸ <Mac>" section of the New Workspace (`+`) menu:
/// one row per known Mac; offline Macs are listed disabled with an "Offline"
/// badge. Choosing a Mac creates a global workspace there and opens its
/// mirror in the window whose menu was clicked
/// (``SupermuxDeviceNewWorkspaceAction``).
///
/// Appended by the `device-new-workspace-menu` touchpoint in
/// `AppDelegate+NewWorkspaceContextMenu.swift`; absent when no Mac is known.
@MainActor
enum SupermuxNewWorkspaceDeviceMenu {
    /// One device row, as rendered (also the socket's view of the menu).
    struct Entry: Equatable {
        let machine: SurfaceMachineID
        let title: String
        let isEnabled: Bool
        let badge: String?
    }

    /// The rows for the currently known Macs.
    static func entries(devices: SupermuxDevices) -> [Entry] {
        devices.devices.map { device in
            Entry(
                machine: device.machine,
                title: device.displayName,
                isEnabled: device.isConnected,
                badge: device.isConnected ? nil : device.linkState == .connecting
                    ? String(localized: "supermux.mirror.newWorkspace.connecting", defaultValue: "Connecting…")
                    : String(localized: "supermux.mirror.newWorkspace.offline", defaultValue: "Offline")
            )
        }
    }

    /// `menu` (or a new one) with the device section appended; `nil` in, `nil`
    /// out when there is nothing to show.
    static func appending(to menu: NSMenu?, windowId: UUID, devices: SupermuxDevices) -> NSMenu? {
        let rows = entries(devices: devices)
        guard !rows.isEmpty else { return menu }
        let menu = menu ?? NSMenu()
        if menu.items.contains(where: { !$0.isSeparatorItem }) {
            menu.addItem(.separator())
        }
        menu.addItem(parentItem(rows: rows, windowId: windowId))
        return menu
    }

    /// The "New Workspace on" parent row and its per-Mac submenu.
    static func parentItem(rows: [Entry], windowId: UUID) -> NSMenuItem {
        let parent = NSMenuItem(
            title: String(localized: "supermux.mirror.newWorkspace.onMac", defaultValue: "New Workspace on"),
            action: nil,
            keyEquivalent: ""
        )
        parent.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        parent.identifier = NSUserInterfaceItemIdentifier(parentIdentifier)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for row in rows {
            let item = NSMenuItem(title: row.title, action: #selector(SupermuxNewWorkspaceDeviceMenuTarget.createOnDevice(_:)), keyEquivalent: "")
            item.target = SupermuxComposition.newWorkspaceDeviceMenuTarget
            item.representedObject = SupermuxNewWorkspaceDeviceMenuTarget.Request(windowId: windowId, machine: row.machine)
            item.isEnabled = row.isEnabled
            item.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            if let badge = row.badge { item.badge = NSMenuItemBadge(string: badge) }
            item.identifier = NSUserInterfaceItemIdentifier(itemIdentifierPrefix + row.machine.rawValue)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    static let parentIdentifier = "supermux.newWorkspace.onMac"
    static let itemIdentifierPrefix = "supermux.newWorkspace.onMac."
}

/// The AppKit target of the device rows (menu items need an object target).
@MainActor
final class SupermuxNewWorkspaceDeviceMenuTarget: NSObject {
    /// What one row creates, and where.
    final class Request: NSObject {
        let windowId: UUID
        let machine: SurfaceMachineID

        init(windowId: UUID, machine: SurfaceMachineID) {
            self.windowId = windowId
            self.machine = machine
        }
    }

    @objc func createOnDevice(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? Request,
              let manager = AppDelegate.shared?.tabManagerFor(windowId: request.windowId),
              SupermuxComposition.deviceNewWorkspace.start(on: request.machine, in: manager) else {
            NSSound.beep()
            return
        }
    }
}

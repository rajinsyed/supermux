import AppKit
import CmuxSurfaceCatalogModel
import Foundation

/// The "New Workspace on ▸" section of the New Workspace (`+`) menu: This Mac
/// first, then one row per known Mac; offline Macs are listed disabled with an
/// "Offline" badge. The row a plain `+` / ⌘N would use in this window right
/// now is checked (``SupermuxNewWorkspaceTarget``). This Mac creates a local
/// workspace even while a mirror is selected; a Mac creates a global
/// workspace there and opens its mirror in the window whose menu was clicked
/// (``SupermuxDeviceNewWorkspaceAction``).
///
/// Appended by the `device-new-workspace-menu` touchpoint in
/// `AppDelegate+NewWorkspaceContextMenu.swift`; absent when no Mac is known.
@MainActor
enum SupermuxNewWorkspaceDeviceMenu {
    /// One row, as rendered (also the socket's view of the menu).
    struct Entry: Equatable {
        /// The Mac the row creates on; `nil` for This Mac.
        let machine: SurfaceMachineID?
        let title: String
        let isEnabled: Bool
        let badge: String?
        /// A plain `+` / ⌘N in this window creates here right now.
        let isCurrentTarget: Bool

        /// The row's identifier suffix: the machine id, or ``thisMacRowID``.
        var rowID: String { machine?.rawValue ?? SupermuxNewWorkspaceDeviceMenu.thisMacRowID }
    }

    /// This Mac, then the currently known Macs.
    static func entries(devices: SupermuxDevices, target: SupermuxNewWorkspaceTarget) -> [Entry] {
        let thisMac = Entry(
            machine: nil,
            title: String(localized: "supermux.mirror.newWorkspace.thisMac", defaultValue: "This Mac"),
            isEnabled: true,
            badge: nil,
            isCurrentTarget: target == .thisMac
        )
        return [thisMac] + devices.devices.map { device in
            Entry(
                machine: device.machine,
                title: device.displayName,
                isEnabled: device.isConnected,
                badge: device.isConnected ? nil : device.linkState == .connecting
                    ? String(localized: "supermux.mirror.newWorkspace.connecting", defaultValue: "Connecting…")
                    : String(localized: "supermux.mirror.newWorkspace.offline", defaultValue: "Offline"),
                isCurrentTarget: target == .device(device.machine)
            )
        }
    }

    /// `menu` (or a new one) with the section appended; `nil` in, `nil` out
    /// when no other Mac is known.
    static func appending(to menu: NSMenu?, windowId: UUID, devices: SupermuxDevices) -> NSMenu? {
        guard !devices.devices.isEmpty else { return menu }
        let target = SupermuxNewWorkspaceTarget.current(in: AppDelegate.shared?.tabManagerFor(windowId: windowId))
        let rows = entries(devices: devices, target: target)
        let menu = menu ?? NSMenu()
        if menu.items.contains(where: { !$0.isSeparatorItem }) {
            menu.addItem(.separator())
        }
        menu.addItem(parentItem(rows: rows, windowId: windowId))
        return menu
    }

    /// The "New Workspace on" parent row and its submenu.
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
            let item = NSMenuItem(title: row.title, action: #selector(SupermuxNewWorkspaceDeviceMenuTarget.create(_:)), keyEquivalent: "")
            item.target = SupermuxComposition.newWorkspaceDeviceMenuTarget
            item.representedObject = SupermuxNewWorkspaceDeviceMenuTarget.Request(windowId: windowId, machine: row.machine)
            item.isEnabled = row.isEnabled
            item.state = row.isCurrentTarget ? .on : .off
            item.image = NSImage(systemSymbolName: row.machine == nil ? "laptopcomputer" : "desktopcomputer", accessibilityDescription: nil)
            if let badge = row.badge { item.badge = NSMenuItemBadge(string: badge) }
            item.identifier = NSUserInterfaceItemIdentifier(itemIdentifierPrefix + row.rowID)
            submenu.addItem(item)
            if row.machine == nil { submenu.addItem(.separator()) }
        }
        parent.submenu = submenu
        return parent
    }

    static let parentIdentifier = "supermux.newWorkspace.onMac"
    static let itemIdentifierPrefix = "supermux.newWorkspace.onMac."
    /// The This Mac row's identifier suffix (and socket `row_id`).
    static let thisMacRowID = "this_mac"
}

/// The AppKit target of the rows (menu items need an object target).
@MainActor
final class SupermuxNewWorkspaceDeviceMenuTarget: NSObject {
    /// What one row creates, and where.
    final class Request: NSObject {
        let windowId: UUID
        /// The Mac to create on; `nil` for This Mac.
        let machine: SurfaceMachineID?

        init(windowId: UUID, machine: SurfaceMachineID?) {
            self.windowId = windowId
            self.machine = machine
        }
    }

    @objc func create(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? Request,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(windowId: request.windowId) else {
            NSSound.beep()
            return
        }
        let started = if let machine = request.machine {
            SupermuxComposition.deviceNewWorkspace.start(on: machine, in: manager)
        } else {
            app.supermuxPerformLocalNewWorkspaceAction(tabManager: manager)
        }
        if !started { NSSound.beep() }
    }
}

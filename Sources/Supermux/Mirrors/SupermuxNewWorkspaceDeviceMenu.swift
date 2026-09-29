import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import SwiftUI

/// The "New Workspace on ▸" section of the New Workspace (`+`) menu: This Mac
/// first, then one row per known Mac; offline Macs are listed disabled with an
/// "Offline" badge. The row a plain `+` / ⌘N would use in this window right
/// now is checked (``SupermuxNewWorkspaceTarget``). This Mac creates a local
/// workspace even while a Cloud VM workspace is selected; a Mac creates a
/// global workspace there, in its home folder, and opens its mirror in the
/// window whose menu was clicked (``SupermuxDeviceNewWorkspaceAction``).
///
/// Appended by the `device-new-workspace-menu` touchpoint in
/// `AppDelegate+NewWorkspaceContextMenu.swift`; absent when no Mac is known.
/// The sidebar empty area's menu shows the same rows
/// (``SupermuxEmptyAreaNewWorkspaceMenu``).
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

        /// The title with the badge after it, for menus that cannot show a
        /// badge (SwiftUI): "M4 Mac (Offline)".
        var titleWithStatus: String {
            guard let badge else { return title }
            return String(
                format: String(localized: "supermux.mirror.newWorkspace.macWithStatus", defaultValue: "%1$@ (%2$@)"),
                locale: .current, title, badge
            )
        }
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

/// The "New Workspace on ▸" submenu of the sidebar empty area's context menu,
/// after upstream's "New Empty Workspace Group" (the
/// `sidebar-empty-area-device-menu` touchpoint in
/// `VerticalTabsSidebar+EmptyAreasAndFooter.swift`): the `+` menu's rows
/// (``SupermuxNewWorkspaceDeviceMenu/entries(devices:target:)``), a Mac that
/// is not connected disabled with its state after the name. This Mac does
/// what a double-click on the empty area does (a local workspace after every
/// row); a Mac creates a global workspace there, in that Mac's home folder,
/// and opens its mirror in this window. Absent when no other Mac is known.
///
/// Its own view so the read of the observable device list stays inside it
/// (snapshot-boundary rule) instead of invalidating the whole empty area.
struct SupermuxEmptyAreaNewWorkspaceMenu: View {
    let tabManager: TabManager

    var body: some View {
        let rows = Self.rows(devices: SupermuxComposition.devices)
        if !rows.isEmpty {
            Divider()
            Menu {
                ForEach(rows, id: \.rowID) { row in
                    Button {
                        Self.create(on: row.machine, in: tabManager)
                    } label: {
                        Label(row.titleWithStatus, systemImage: row.machine == nil ? "laptopcomputer" : "desktopcomputer")
                    }
                    .disabled(!row.isEnabled)
                    if row.machine == nil { Divider() }
                }
            } label: {
                Label(
                    String(localized: "supermux.mirror.newWorkspace.onMac", defaultValue: "New Workspace on"),
                    systemImage: "desktopcomputer"
                )
            }
        }
    }

    /// The rows as shown (also the socket's view of this menu): This Mac,
    /// then each known Mac; none when no other Mac is known.
    @MainActor
    static func rows(devices: SupermuxDevices) -> [SupermuxNewWorkspaceDeviceMenu.Entry] {
        guard !devices.devices.isEmpty else { return [] }
        return SupermuxNewWorkspaceDeviceMenu.entries(devices: devices, target: .thisMac)
    }

    /// One row's action: on `machine`, or on this Mac (`nil`) exactly like the
    /// empty area's double-click. Beeps when nothing could start.
    @MainActor
    @discardableResult
    static func create(on machine: SurfaceMachineID?, in tabManager: TabManager) -> Bool {
        let started = if let machine {
            SupermuxComposition.deviceNewWorkspace.start(on: machine, in: tabManager)
        } else {
            AppDelegate.shared?.performSidebarEmptyAreaNewWorkspaceAction(tabManager: tabManager)
                ?? (tabManager.addWorkspaceIfActive(placementOverride: .end) != nil)
        }
        if !started { NSSound.beep() }
        return started
    }
}

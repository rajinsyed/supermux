import CmuxSurfaceCatalogModel
import Foundation

/// Where a plain New Workspace (the titlebar `+`, ⌘N, a double-click on the
/// sidebar's empty area) creates in a window right now. Mirrors the routing
/// of `AppDelegate.performNewWorkspaceAction`: a selected device mirror (or
/// any workspace the fork's device facade handles) still creates on THIS Mac,
/// since creating on another Mac is an explicit "New Workspace on ▸ <Mac>"
/// choice; a workspace backed by a Cloud VM, or by a Mac only upstream's own
/// path handles, creates there; anything else creates on this Mac.
///
/// The `+` menu checks this target's row; the `+` tooltip names another Mac
/// only for ``device(_:)``, which plain New Workspace no longer produces, so
/// it stays upstream's.
enum SupermuxNewWorkspaceTarget: Equatable {
    case thisMac
    /// Another Mac the fork creates on (``SupermuxDeviceNewWorkspaceAction``).
    case device(SurfaceMachineID)
    /// A Cloud VM, or a Mac only upstream's own path handles.
    case elsewhere

    /// The target for `manager`'s window (this Mac without a window).
    @MainActor
    static func current(in manager: TabManager?) -> Self {
        guard let workspace = manager?.selectedWorkspace else { return .thisMac }
        if isForkDeviceWorkspace(workspace) { return .thisMac }
        if workspace.deviceMachineForNewWorkspace != nil { return .elsewhere }
        if let vmID = workspace.cloudVMID, !vmID.isEmpty { return .elsewhere }
        return .thisMac
    }

    /// Whether `workspace` routes upstream's device New Workspace to a Mac the
    /// fork handles (a device mirror, or a workspace of one device pane). A
    /// plain New Workspace there creates on this Mac instead (touchpoints
    /// #571 and #620).
    @MainActor
    static func isForkDeviceWorkspace(_ workspace: Workspace?) -> Bool {
        guard let machine = workspace?.deviceMachineForNewWorkspace else { return false }
        return SupermuxComposition.deviceNewWorkspace.handles(machine)
    }

    /// The `+` button's help for `manager`'s window: "New Workspace on <Mac>"
    /// (with the shortcut) while + creates on another Mac, else `defaultHelp`.
    @MainActor
    static func plusButtonHelp(in manager: TabManager?, default defaultHelp: String) -> String {
        guard case .device(let machine) = current(in: manager) else { return defaultHelp }
        let name = SupermuxComposition.devices.device(for: machine)?.displayName ?? machine.rawValue
        return KeyboardShortcutSettings.Action.newTab.tooltip(
            String(localized: "supermux.mirror.newWorkspace.plusHelp", defaultValue: "New Workspace on \(name)")
        )
    }
}

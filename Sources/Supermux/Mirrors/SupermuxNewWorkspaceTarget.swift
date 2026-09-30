import CmuxSurfaceCatalogModel
import Foundation

/// Where a plain New Workspace (the titlebar `+`, ⌘N) creates in a window
/// right now. Mirrors the routing of `AppDelegate.performNewWorkspaceAction`:
/// a selected workspace backed by another Mac creates there, one backed by a
/// Cloud VM creates on the VM, anything else creates on this Mac.
///
/// The `+` menu checks this target's row and the `+` tooltip names the other
/// Mac, so + and ⌘N never create remotely without saying so.
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
        if let machine = workspace.deviceMachineForNewWorkspace {
            return SupermuxComposition.deviceNewWorkspace.handles(machine) ? .device(machine) : .elsewhere
        }
        if let vmID = workspace.cloudVMID, !vmID.isEmpty { return .elsewhere }
        return .thisMac
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

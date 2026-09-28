import CmuxSurfaceCatalogModel
import Foundation

/// Chooses the main window an auto-opened mirror lands in: the window that
/// already holds most mirrors of that device (so one Mac's workspaces stay
/// together), else the preferred main window for workspace creation (the key
/// window, then the active one). Never creates a window.
@MainActor
struct SupermuxDeviceMirrorWindowPicker {
    let index: SupermuxDeviceWorkspaceIndex

    func tabManager(forDevice machine: SurfaceMachineID) -> TabManager? {
        var counts: [ObjectIdentifier: (manager: TabManager, count: Int)] = [:]
        for mirror in index.mirrors() where mirror.ref.machine == machine {
            guard let manager = mirror.workspace.owningTabManager, !manager.isFinalizedForWindowClose else { continue }
            counts[ObjectIdentifier(manager), default: (manager, 0)].count += 1
        }
        if let best = counts.values.max(by: { $0.count < $1.count }) {
            return best.manager
        }
        let context = AppDelegate.shared?.preferredMainWindowContextForWorkspaceCreation(debugSource: "supermux.autoMirror")
        guard let manager = context?.tabManager, !manager.isFinalizedForWindowClose else { return nil }
        return manager
    }
}

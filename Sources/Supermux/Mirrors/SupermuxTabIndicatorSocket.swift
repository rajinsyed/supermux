#if DEBUG
import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

/// `supermux.devices.mirror.*` tab-indicator drivers (DEBUG builds only),
/// dispatched from ``SupermuxMirrorSocketCommands``; they drive
/// `loopback_agent_activity_e2e.py`:
///
/// - `tab_indicators {workspace_id}`: what each tab of an open workspace — a
///   device mirror or a local one — draws for its agent, read straight from
///   the pane tab bars.
/// - `dock_tab {surface_id}`: the same for the Dock tab showing that panel
///   (`in_dock` false while no Dock holds it).
/// - `move_into_dock {surface_id}`: moves a workspace tab into its window's
///   Dock, as dragging it onto the Dock does.
/// - `reset_tab_loading {workspace_id, panel_id}`: clears one tab's spinner,
///   the state a tab is created in, so a test can stand in for a mirror tab
///   projected after its overlay arrived.
///
/// `tab_indicators` reports per tab `tab_id`, `pane_id`, `panel_id`, `panel_type`, `title`,
/// `is_selected`, `is_loading` (Bonsplit's working spinner, also true while
/// it is held off because the window is off screen), `spinner_held_off_screen`
/// (that hold, ``SupermuxTabActivitySync``),
/// `shows_notification_badge` (the unread dot), `remote_surface_id` (for a
/// mirror tab: the other Mac's terminal id it shows, upper-cased) and
/// `lifecycle` (the panel's own agent lifecycle values by agent key). The
/// workspace's status pills come back as `status_entries` with their
/// `work_state` (`running`/`subagents`/`waiting`).
@MainActor
enum SupermuxTabIndicatorSocket {
    static let methods: Set<Substring> = ["tab_indicators", "dock_tab", "move_into_dock", "reset_tab_loading"]

    static func handle(_ method: Substring, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "dock_tab": return try dockTab(params)
        case "move_into_dock": return try moveIntoDock(params)
        case "reset_tab_loading": return try resetTabLoading(params)
        default: return try tabIndicators(params)
        }
    }

    static func tabIndicators(_ params: [String: Any]) throws -> [String: Any] {
        let workspace = try SupermuxMirrorSocketCommands.mirrorWorkspace(params)
        let controller = workspace.bonsplitController
        var tabs: [[String: Any]] = []
        for pane in controller.allPaneIds {
            let selected = controller.selectedTabId(inPane: pane)
            for tab in controller.tabs(inPane: pane) {
                tabs.append(describe(tab, pane: pane, isSelected: tab.id == selected, in: workspace))
            }
        }
        return [
            "workspace_id": workspace.id.uuidString,
            "is_mirror": SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace),
            "tabs": tabs,
            "status_entries": workspace.sidebarStatusEntriesInDisplayOrder().map { entry -> [String: Any] in
                [
                    "key": entry.key,
                    "value": entry.value,
                    "icon": entry.icon ?? NSNull(),
                    "work_state": entry.workState?.rawValue ?? NSNull(),
                ]
            },
        ]
    }

    private static func describe(_ tab: Bonsplit.Tab, pane: PaneID, isSelected: Bool, in workspace: Workspace) -> [String: Any] {
        let panelID = workspace.panelIdFromSurfaceId(tab.id)
        let panel = panelID.flatMap { workspace.panels[$0] }
        let projection = panelID.flatMap { SurfaceCatalog.shared.projection(forPanel: $0) }
        let remoteSurfaceID = projection.flatMap { $0.resource.machine.isDevice ? $0.resource.key.uppercased() : nil }
        let lifecycle = panelID.flatMap { workspace.agentLifecycleStatesByPanelId[$0] }?.mapValues(\.rawValue) ?? [:]
        let heldOffScreen = SupermuxTabActivitySync.shared.isHeldOffScreen(tab.id)
        let isLoading = tab.isLoading || heldOffScreen
        return [
            "tab_id": tab.id.uuid.uuidString,
            "pane_id": pane.id.uuidString,
            "panel_id": panelID?.uuidString ?? NSNull(),
            "panel_type": panel?.panelType.rawValue ?? NSNull(),
            "title": tab.title,
            "is_selected": isSelected,
            "is_loading": isLoading,
            "spinner_held_off_screen": heldOffScreen,
            "shows_notification_badge": tab.showsNotificationBadge,
            "remote_surface_id": remoteSurfaceID ?? NSNull(),
            "lifecycle": lifecycle,
        ]
    }

    static func dockTab(_ params: [String: Any]) throws -> [String: Any] {
        let panelID = try uuid(params, "surface_id")
        guard let dock = DockSplitStore.liveStore(containingPanel: panelID),
              let tabID = dock.surfaceId(forPanelId: panelID),
              let tab = dock.bonsplitController.tab(tabID) else {
            return ["in_dock": false]
        }
        let lifecycle = dock.agentRuntimeByPanelId[panelID]?.agentLifecycleStates.mapValues(\.rawValue) ?? [:]
        let heldOffScreen = SupermuxTabActivitySync.shared.isHeldOffScreen(tabID)
        let isLoading = tab.isLoading || heldOffScreen
        return [
            "in_dock": true,
            "dock_owner_id": dock.workspaceId.uuidString,
            "tab_id": tabID.uuid.uuidString,
            "panel_type": dock.panels[panelID]?.panelType.rawValue ?? NSNull(),
            "is_loading": isLoading,
            "spinner_held_off_screen": heldOffScreen,
            "lifecycle": lifecycle,
        ]
    }

    static func moveIntoDock(_ params: [String: Any]) throws -> [String: Any] {
        let panelID = try uuid(params, "surface_id")
        guard let app = AppDelegate.shared,
              let owner = app.workspaceContainingPanel(panelId: panelID),
              let tabID = owner.workspace.surfaceIdFromPanelId(panelID),
              let dock = app.windowDock(for: owner.tabManager),
              let pane = dock.resolvePane(requestedPaneID: nil) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id does not name a workspace tab whose window has a Dock")
        }
        let moved = app.moveSurfaceIntoDock(
            sourceTabId: tabID.uuid,
            destinationDock: dock,
            destination: .insert(targetPane: pane, targetIndex: nil)
        )
        return ["moved": moved, "dock_owner_id": dock.workspaceId.uuidString]
    }

    static func resetTabLoading(_ params: [String: Any]) throws -> [String: Any] {
        let workspace = try SupermuxMirrorSocketCommands.mirrorWorkspace(params)
        let panelID = try uuid(params, "panel_id")
        guard let tab = workspace.surfaceIdFromPanelId(panelID) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "panel_id does not name a tab of the workspace")
        }
        SupermuxTabActivitySync.shared.setWorking(false, tab: tab, in: workspace.bonsplitController, windowOnScreen: true)
        return ["tab_id": tab.uuid.uuidString]
    }

    private static func uuid(_ params: [String: Any], _ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try SupermuxMirrorSocketCommands.string(params, key)) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "\(key) is not a UUID")
        }
        return id
    }
}
#endif

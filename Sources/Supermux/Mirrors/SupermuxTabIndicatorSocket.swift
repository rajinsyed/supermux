#if DEBUG
import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

/// `supermux.devices.mirror.tab_indicators {workspace_id}` (DEBUG builds only):
/// what each tab of an open workspace — a device mirror or a local one — draws
/// for its agent, read straight from the pane tab bars. Dispatched from
/// ``SupermuxMirrorSocketCommands``; drives `loopback_agent_activity_e2e.py`.
///
/// Each tab reports `tab_id`, `pane_id`, `panel_id`, `panel_type`, `title`,
/// `is_selected`, `is_loading` (Bonsplit's working spinner),
/// `shows_notification_badge` (the unread dot), `remote_surface_id` (for a
/// mirror tab: the other Mac's terminal id it shows, upper-cased) and
/// `lifecycle` (the panel's own agent lifecycle values by agent key). The
/// workspace's status pills come back as `status_entries` with their
/// `work_state` (`running`/`subagents`/`waiting`).
@MainActor
enum SupermuxTabIndicatorSocket {
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
        return [
            "tab_id": tab.id.uuid.uuidString,
            "pane_id": pane.id.uuidString,
            "panel_id": panelID?.uuidString ?? NSNull(),
            "panel_type": panel?.panelType.rawValue ?? NSNull(),
            "title": tab.title,
            "is_selected": isSelected,
            "is_loading": tab.isLoading,
            "shows_notification_badge": tab.showsNotificationBadge,
            "remote_surface_id": remoteSurfaceID ?? NSNull(),
            "lifecycle": lifecycle,
        ]
    }
}
#endif

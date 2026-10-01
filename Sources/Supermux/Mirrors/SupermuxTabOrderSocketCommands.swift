#if DEBUG
import Bonsplit
import Foundation

/// `supermux.devices.mirror.*` E2E drivers for where a new tab lands, each
/// running the exact call its UI entry point makes (DEBUG builds only).
/// Dispatched from ``SupermuxMirrorSocketCommands``; work in any open
/// workspace, a device mirror or a local one.
///
/// - `tab_bar_new_tab {workspace_id, pane_id?}` — the pane tab bar's `+`
///   (`requestNewTab(kind: "terminal")`); the pane defaults to the focused one.
/// - `tab_context_action {workspace_id, surface_id, action}` — a tab's context
///   menu item; `action` is a Bonsplit `TabContextAction` raw value, e.g.
///   `newTerminalToRight`.
@MainActor
enum SupermuxTabOrderSocketCommands {
    static let methods: Set<Substring> = ["tab_bar_new_tab", "tab_context_action"]

    static func handle(_ method: Substring, params: [String: Any]) throws -> [String: Any] {
        let workspace = try SupermuxMirrorSocketCommands.mirrorWorkspace(params)
        switch method {
        case "tab_bar_new_tab":
            let pane = try pane(params, in: workspace)
            workspace.bonsplitController.requestNewTab(kind: "terminal", inPane: pane)
            return ["workspace_id": workspace.id.uuidString, "pane_id": pane.id.uuidString]
        case "tab_context_action":
            let rawAction = try SupermuxMirrorSocketCommands.string(params, "action")
            guard let action = TabContextAction(rawValue: rawAction) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "unknown tab context action \(rawAction)")
            }
            guard let surfaceID = UUID(uuidString: try SupermuxMirrorSocketCommands.string(params, "surface_id")),
                  let tab = workspace.surfaceIdFromPanelId(surfaceID),
                  let pane = workspace.paneId(forPanelId: surfaceID) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id is not a tab of this workspace")
            }
            workspace.bonsplitController.requestTabContextAction(action, for: tab, inPane: pane)
            return ["workspace_id": workspace.id.uuidString, "pane_id": pane.id.uuidString]
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "unknown mirror method \(method)")
        }
    }

    /// The `pane_id` pane, or the workspace's focused (else first) pane.
    private static func pane(_ params: [String: Any], in workspace: Workspace) throws -> PaneID {
        let panes = workspace.bonsplitController.allPaneIds
        if let raw = params["pane_id"] as? String {
            guard let id = UUID(uuidString: raw), let pane = panes.first(where: { $0.id == id }) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "pane_id is not a pane of this workspace")
            }
            return pane
        }
        guard let pane = workspace.bonsplitController.focusedPaneId ?? panes.first else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "workspace has no pane")
        }
        return pane
    }
}
#endif

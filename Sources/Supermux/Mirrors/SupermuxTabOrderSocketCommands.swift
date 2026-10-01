#if DEBUG
import Bonsplit
import CmuxSurfaceCatalogModel
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
/// - `lose_next_create_reply {}` — the next device terminal create reaches its
///   Mac and is answered there, but the answer is dropped and the create fails
///   as a lost link would (``SupermuxTabOrderDebug``).
/// - `pending_creations {workspace_id}` — the workspace's reserved panes whose
///   terminal is still being created: `panel_id`, `request_id` and `failure`
///   (the pane's failure text, or null while it waits).
/// - `retry_pending {workspace_id, forget_host_capabilities?}` — the Retry of
///   every failed reserved pane (`retried`: their panel ids). With
///   `forget_host_capabilities`, each pane's Mac's capability cache is emptied
///   first, as a reconnect does before its capability fetch returns.
/// - `tab_chrome {workspace_id, surface_id}` — what the surface's tab draws:
///   `shows_notification_badge`, `is_loading` and `presence` (the shared-terminal
///   accessory and context-menu size section: `shows_accessory`, `participants`,
///   `can_disconnect_others`, `size_mode`; null when the tab has none).
@MainActor
enum SupermuxTabOrderSocketCommands {
    static let methods: Set<Substring> = [
        "tab_bar_new_tab", "tab_context_action", "lose_next_create_reply", "pending_creations", "retry_pending",
        "tab_chrome",
    ]

    static func handle(_ method: Substring, params: [String: Any]) throws -> [String: Any] {
        if method == "lose_next_create_reply" {
            SupermuxTabOrderDebug.losesNextCreateReply = true
            return ["armed": true]
        }
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
        case "pending_creations":
            return ["workspace_id": workspace.id.uuidString, "pending": pendingCreations(in: workspace)]
        case "tab_chrome":
            guard let surfaceID = UUID(uuidString: try SupermuxMirrorSocketCommands.string(params, "surface_id")),
                  let tabID = workspace.surfaceIdFromPanelId(surfaceID),
                  let tab = workspace.bonsplitController.tab(tabID) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id is not a tab of this workspace")
            }
            return [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
                "shows_notification_badge": tab.showsNotificationBadge,
                "is_loading": tab.isLoading,
                "presence": tab.presence.map { presencePayload($0) as Any } ?? NSNull(),
            ]
        case "retry_pending":
            let failed = workspace.cloudPendingCreations.values
                .filter { workspace.cloudMaterializationFailures[$0.panelID] != nil }
            if params["forget_host_capabilities"] as? Bool == true {
                for reservation in failed {
                    guard let instance = reservation.machine.deviceInstance else { continue }
                    SupermuxComposition.devices.capabilitiesByInstance[instance] = nil
                }
            }
            let retried = failed.map(\.panelID).filter { workspace.retryReservedCloudTerminalPane(surfaceId: $0) }
            return ["workspace_id": workspace.id.uuidString, "retried": retried.map(\.uuidString)]
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "unknown mirror method \(method)")
        }
    }

    /// Every reserved pane of `workspace` still waiting for its terminal.
    private static func pendingCreations(in workspace: Workspace) -> [[String: Any]] {
        workspace.cloudPendingCreations.values
            .sorted { $0.panelID.uuidString < $1.panelID.uuidString }
            .map { reservation -> [String: Any] in
                [
                    "panel_id": reservation.panelID.uuidString,
                    "request_id": reservation.requestID?.uuidString ?? NSNull(),
                    "failure": workspace.cloudMaterializationFailures[reservation.panelID]?.detail ?? NSNull(),
                ]
            }
    }

    /// A tab's shared-terminal presence: its avatar accessory and the size
    /// section of its context menu.
    private static func presencePayload(_ presence: TabPresence) -> [String: Any] {
        [
            "shows_accessory": presence.showsAccessory,
            "participants": presence.participants.map { participant -> [String: Any] in
                [
                    "id": participant.id,
                    "initials": participant.initials,
                    "symbol": participant.symbolName.map { $0 as Any } ?? NSNull(),
                    "name": participant.accessibilityName,
                    "is_owner": participant.isOwner,
                ]
            },
            "can_disconnect_others": presence.canDisconnectOthers,
            "size_mode": presence.sizeMode.rawValue,
        ]
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

/// A DEBUG fault for the tab-order E2E: the reply to one device terminal
/// create is lost after its Mac made the terminal, the case a request's Retry
/// exists for. Read by the `mirror-terminal-to-right` fence in
/// `DeviceSurfaceProvider+TerminalLayout.swift`.
@MainActor
enum SupermuxTabOrderDebug {
    static var losesNextCreateReply = false

    /// Whether this create's reply is to be dropped; disarms the fault.
    static func takeLostReply() -> Bool {
        defer { losesNextCreateReply = false }
        return losesNextCreateReply
    }
}
#endif

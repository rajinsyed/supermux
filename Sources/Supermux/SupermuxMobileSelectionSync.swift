import CmuxControlSocket
import Foundation

/// Mac-side selection mutations used by the phone's bidirectional tab sync.
///
/// Both handlers route through the same shared actions as the control socket:
/// workspace selection uses ``TerminalController/controlSelectWorkspace(routing:workspaceID:)``
/// and panel selection uses ``TerminalController/controlSurfaceFocus(routing:surfaceID:)``.
/// This keeps sidebar, keyboard, socket, and phone focus semantics aligned.
extension TerminalController {
    /// Selects one explicit workspace on behalf of the paired phone.
    func v2SupermuxWorkspaceSelect(params: [String: Any]) -> V2CallResult {
        guard v2HasNonNullParam(params, "workspace_id"),
              let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid workspace_id",
                data: nil
            )
        }

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: nil,
            paneID: nil
        )
        switch controlSelectWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: ["workspace_id": workspaceID.uuidString]
            )
        case .resolved(let windowID):
            return .ok([
                "workspace_id": workspaceID.uuidString,
                "window_id": v2OrNull(windowID?.uuidString),
            ])
        }
    }

    /// Selects one explicit panel of any kind and its owning workspace on behalf
    /// of the paired phone.
    func v2SupermuxPanelSelect(params: [String: Any]) -> V2CallResult {
        guard v2HasNonNullParam(params, "workspace_id"),
              let workspaceID = v2UUID(params, "workspace_id"),
              v2HasNonNullParam(params, "panel_id"),
              let panelID = v2UUID(params, "panel_id") else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid workspace_id/panel_id",
                data: nil
            )
        }

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: panelID,
            paneID: nil
        )
        switch controlSurfaceFocus(routing: routing, surfaceID: panelID) {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFound:
            return .err(
                code: "not_found",
                message: "Panel not found",
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
        case .focused(let windowID, let focusedWorkspaceID, let focusedPanelID):
            return .ok([
                "workspace_id": focusedWorkspaceID.uuidString,
                "panel_id": focusedPanelID.uuidString,
                "window_id": v2OrNull(windowID?.uuidString),
            ])
        }
    }

    /// Selects one explicit terminal tab and its owning workspace on behalf of
    /// the paired phone.
    func v2SupermuxTerminalSelect(params: [String: Any]) -> V2CallResult {
        guard v2HasNonNullParam(params, "workspace_id"),
              let workspaceID = v2UUID(params, "workspace_id"),
              v2HasNonNullParam(params, "terminal_id"),
              let terminalID = v2UUID(params, "terminal_id") else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid workspace_id/terminal_id",
                data: nil
            )
        }

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: terminalID,
            paneID: nil
        )
        switch controlSurfaceFocus(routing: routing, surfaceID: terminalID) {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFound:
            return .err(
                code: "not_found",
                message: "Terminal not found",
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "terminal_id": terminalID.uuidString,
                ]
            )
        case .focused(let windowID, let focusedWorkspaceID, let focusedTerminalID):
            return .ok([
                "workspace_id": focusedWorkspaceID.uuidString,
                "terminal_id": focusedTerminalID.uuidString,
                "window_id": v2OrNull(windowID?.uuidString),
            ])
        }
    }
}

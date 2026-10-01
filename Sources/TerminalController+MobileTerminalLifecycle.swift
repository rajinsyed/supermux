import Foundation
import CmuxControlSocket

/// The two terminal-lifecycle verbs another Mac's Devices sidebar needs that
/// the mobile plane did not have: close one terminal surface, and rename (or
/// clear the custom name of) one terminal surface. Both resolve the target
/// exactly as `mobile.terminal.input` does, so an attach ticket's terminal
/// scope applies unchanged, and both mutate through the same code paths the
/// local socket verbs use (`surface.close`, `surface.action rename`).
extension TerminalController {
    /// `mobile.terminal.close {workspace_id?, surface_id}`: end the terminal
    /// (its process and pane) on this Mac. Refuses the workspace's last
    /// surface, matching the local socket contract.
    func v2MobileTerminalClose(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: String(localized: "devices.host.surfaceNotFound", defaultValue: "Terminal surface not found"), data: nil)
        }
        let workspace = resolved.workspace
        let surfaceID = resolved.surfaceID
        var resolution: ControlSurfaceCloseResolution = .closeFailed(surfaceID)
        // SUPERMUX:begin mobile-terminal-close-force
        // An explicit `force` ends a terminal that runs a program (the viewer
        // asked its user first); without it the host refuses, as `surface.close` does.
        let supermuxForce = v2Bool(params, "force") == true
        // SUPERMUX:end mobile-terminal-close-force
        v2MainSync {
            resolution = controlSurfaceClose(
                routing: ControlRoutingSelectors(
                    hasWindowIDParam: false, windowID: nil, groupID: nil,
                    workspaceID: workspace.id, surfaceID: surfaceID, paneID: nil
                ),
                surfaceID: surfaceID,
                // SUPERMUX:begin mobile-terminal-close-force (upstream's last argument gains a trailing comma)
                hasSurfaceIDParam: true,
                force: supermuxForce
                // SUPERMUX:end mobile-terminal-close-force
            )
        }
        if case .lastSurface = resolution {
            return .err(code: "invalid_state", message: String(localized: "devices.host.lastSurface", defaultValue: "Cannot close the last surface"), data: nil)
        }
        // SUPERMUX:begin mobile-terminal-close-force
        // The same code `surface.close` and `workspace.close` use, never the
        // sanitized `internal_error`, so the viewer can ask and retry with force.
        if case .confirmationRequired = resolution {
            return .err(code: "confirmation_required", message: controlSurfaceCloseStrings().confirmationRequired, data: [
                "surface_id": surfaceID.uuidString,
            ])
        }
        // SUPERMUX:end mobile-terminal-close-force
        guard case .closed = resolution else {
            return .err(code: "internal_error", message: String(localized: "devices.host.closeFailed", defaultValue: "Failed to close surface"), data: [
                "surface_id": surfaceID.uuidString,
            ])
        }
        return .ok([
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceID.uuidString,
            "closed": true,
        ])
    }

    /// `mobile.terminal.rename {workspace_id?, surface_id, title}`: set the
    /// terminal's custom title; an empty title clears it so the shell's own
    /// title shows again.
    func v2MobileTerminalRename(params: [String: Any]) -> V2CallResult {
        guard let rawTitle = params["title"] as? String else {
            return .err(code: "invalid_params", message: String(localized: "devices.host.invalidTitle", defaultValue: "Missing or invalid title"), data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: String(localized: "devices.host.surfaceNotFound", defaultValue: "Terminal surface not found"), data: nil)
        }
        let workspace = resolved.workspace
        let surfaceID = resolved.surfaceID
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        v2MainSync {
            let panelID = workspace.controlTabTarget(for: surfaceID)?.panelID ?? surfaceID
            _ = workspace.setPanelCustomTitle(panelId: panelID, title: title.isEmpty ? nil : title)
        }
        return .ok([
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceID.uuidString,
            "title": v2OrNull(title.isEmpty ? nil : title),
        ])
    }
}

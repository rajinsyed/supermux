import CmuxSimulatorUI
import Foundation

/// The Simulator toolbar controls another Mac's simulator viewer
/// (`SupermuxRemoteSimulatorPanel`) runs on this Mac's panel. Touch, text,
/// keys and hardware buttons ride the v2 stream lane itself; rotation, the
/// software keyboard and the appearance are not on that wire.
private enum SupermuxSimulatorControlAction: String {
    case rotateLeft = "rotate_left"
    case rotateRight = "rotate_right"
    case toggleSoftwareKeyboard = "toggle_software_keyboard"
    case toggleAppearance = "toggle_appearance"
}

extension TerminalController {
    /// `mobile.supermux.simulator.control {workspace_id, panel_id, action}`:
    /// runs one control on a Simulator panel of that workspace, the same
    /// coordinator call as the panel's own toolbar.
    func v2SupermuxSimulatorControl(params: [String: Any]) async -> V2CallResult {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            return .err(code: "capability_disabled", message: "Simulator panes are disabled", data: nil)
        }
        guard let workspaceID = v2UUID(params, "workspace_id"),
              let panelID = v2UUID(params, "panel_id"),
              let action = v2RawString(params, "action").flatMap(SupermuxSimulatorControlAction.init(rawValue:)) else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid workspace_id/panel_id/action",
                data: nil
            )
        }
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: panelID),
              located.workspaceId == workspaceID,
              let workspace = located.tabManager.tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.panels[panelID] as? SimulatorPanel else {
            return .err(code: "not_found", message: "Simulator panel not found", data: [
                "workspace_id": workspaceID.uuidString,
                "panel_id": panelID.uuidString,
            ])
        }
        let coordinator = panel.coordinator
        switch action {
        case .rotateLeft:
            coordinator.rotateLeft()
        case .rotateRight:
            coordinator.rotateRight()
        case .toggleSoftwareKeyboard:
            coordinator.toggleSoftwareKeyboard()
        case .toggleAppearance:
            await coordinator.toggleAppearance()
        }
        return .ok(["ok": true, "panel_id": panelID.uuidString, "action": action.rawValue])
    }
}

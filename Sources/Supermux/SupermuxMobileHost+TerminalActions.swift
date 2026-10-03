import Foundation
import SupermuxMobileCore

/// The host side of a terminal action another Mac's device mirror forwards
/// (capability `supermux.terminal_actions.v1`).
///
/// `mobile.supermux.terminal.action {workspace_id, terminal_id, action}` runs
/// one of ``SupermuxDeviceTerminalActions/forwardedActions`` on that terminal
/// here, exactly as on this Mac: `clear_screen` (Cmd+K) clears the screen and
/// the scrollback, `reset` resets the terminal, and `focus_in` / `focus_out`
/// focus or unfocus it, so its Ghostty sends the program the focus report it
/// asked for (mode 1004), once: an unchanged focus reports nothing. A mirror
/// is a view of this terminal, so an action that changes the terminal's own
/// state must run here too, or the next replay brings back what the viewer
/// cleared. Result: `{performed}` (`clear_screen` on the alternate screen
/// performs nothing, as here).
extension TerminalController {
    func v2SupermuxTerminalAction(params: [String: Any]) -> V2CallResult {
        guard let workspaceID = v2UUID(params, "workspace_id"),
              let terminalID = v2UUID(params, "terminal_id"),
              let action = params["action"] as? String,
              SupermuxDeviceTerminalActions.forwardedActions.contains(action) else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id/terminal_id/action", data: nil)
        }
        guard let workspace = Workspace.liveWorkspace(id: workspaceID) else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceID.uuidString])
        }
        guard let panel = workspace.terminalPanel(for: terminalID) else {
            return .err(code: "not_found", message: "Terminal not found", data: ["terminal_id": terminalID.uuidString])
        }
        if SupermuxDeviceTerminalActions.focusActions.contains(action) {
            panel.surface.setFocus(action == "focus_in")
            return .ok(["performed": true])
        }
        return .ok(["performed": panel.performBindingAction(action)])
    }
}

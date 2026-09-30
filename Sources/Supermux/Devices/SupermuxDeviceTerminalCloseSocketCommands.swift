#if DEBUG
import CmuxSurfaceCatalogModel
import Foundation

/// DEBUG-only `supermux.devices.terminal_close.*` drivers for
/// `tests/supermux/loopback_mirror_tab_close_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``:
///
/// - `terminal_close.inspect {workspace_id}`: every device-mirror pane of that
///   workspace (`panel_id`, `remote_surface_id`, `has_session`, `attached`,
///   `connecting`, `overlay_title`) and the workspace's failure card
///   (`title`, `message`, `recovery`) or null.
/// - `terminal_close.answer {answer?: "close" | "cancel" | "clear"}`: sets (or,
///   with `clear`, removes) the answer the "Close “X” on <Mac>?" prompt takes
///   without showing itself, so no modal blocks a run. Setting an answer also
///   empties the log of asked prompts; every call returns the current answer
///   and that log (`asked: [{title, message, device}]`).
/// - `terminal_close.needs_confirm {workspace_id, surface_id}`: whether this Mac
///   would ask before closing that terminal of its own (`panelNeedsConfirmClose`).
@MainActor
enum SupermuxDeviceTerminalCloseSocketCommands {
    static let methodPrefix = "terminal_close."

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Whether `name` (the part after `supermux.devices.`) is one of these drivers.
    static func handles<S: StringProtocol>(_ name: S) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle<S: StringProtocol>(_ name: S, _ params: [String: Any]) throws -> [String: Any] {
        switch String(name.dropFirst(methodPrefix.count)) {
        case "inspect": return try inspect(params)
        case "answer": return try answer(params)
        case "needs_confirm": return try needsConfirm(params)
        default: throw HookError(message: "unknown terminal_close method \(name)")
        }
    }

    private static func inspect(_ params: [String: Any]) throws -> [String: Any] {
        let workspace = try liveWorkspace(params)
        let catalog = SurfaceCatalog.shared
        let projections = catalog.projections
            .filter { $0.workspaceID == workspace.id && $0.resource.machine.isDevice }
            .sorted { $0.panelID.uuidString < $1.panelID.uuidString }
        let panes = projections.map { projection -> [String: Any] in
            let provider = catalog.provider(for: projection.resource.machine) as? DeviceSurfaceProvider
            let attachment = provider?.sessions[projection.panelID]?.attachment
            return [
                "panel_id": projection.panelID.uuidString,
                "remote_surface_id": projection.resource.key,
                "has_session": attachment != nil,
                "attached": attachment?.isConnected ?? false,
                "connecting": attachment?.isConnecting ?? false,
                "overlay_title": attachment?.presentation?.title ?? NSNull(),
            ]
        }
        var card: Any = NSNull()
        if let failure = workspace.cloudPaneCreationFailureStore.failure {
            card = ["title": failure.displayTitle, "message": failure.errorText, "recovery": failure.recoveryText]
        }
        return ["workspace_id": workspace.id.uuidString, "panes": panes, "failure_card": card]
    }

    private static func answer(_ params: [String: Any]) throws -> [String: Any] {
        switch params["answer"] as? String {
        case nil:
            break
        case "clear":
            SupermuxDeviceTerminalCloseDebug.answer = nil
        case let raw?:
            guard let answer = SupermuxDeviceTerminalCloseDebug.Answer(rawValue: raw) else {
                throw HookError(message: "answer must be close, cancel or clear")
            }
            SupermuxDeviceTerminalCloseDebug.answer = answer
            SupermuxDeviceTerminalCloseDebug.asked = []
        }
        return [
            "answer": SupermuxDeviceTerminalCloseDebug.answer?.rawValue ?? NSNull(),
            "asked": SupermuxDeviceTerminalCloseDebug.asked,
        ]
    }

    private static func needsConfirm(_ params: [String: Any]) throws -> [String: Any] {
        let workspace = try liveWorkspace(params)
        guard let raw = params["surface_id"] as? String, let surfaceID = UUID(uuidString: raw) else {
            throw HookError(message: "surface_id is required")
        }
        return [
            "exists": workspace.panels[surfaceID] != nil,
            "needs_confirm": workspace.panelNeedsConfirmClose(panelId: surfaceID),
        ]
    }

    private static func liveWorkspace(_ params: [String: Any]) throws -> Workspace {
        guard let raw = params["workspace_id"] as? String, let id = UUID(uuidString: raw),
              let workspace = Workspace.liveWorkspace(id: id) else {
            throw HookError(message: "workspace_id does not name an open workspace")
        }
        return workspace
    }
}

/// The device-terminal close prompt's DEBUG pre-answer and the log of the
/// prompts it answered, so the E2E never shows a modal and can tell whether a
/// close asked at all.
@MainActor
enum SupermuxDeviceTerminalCloseDebug {
    enum Answer: String {
        case close
        case cancel
    }

    static var answer: Answer?
    static var asked: [[String: Any]] = []
}
#endif

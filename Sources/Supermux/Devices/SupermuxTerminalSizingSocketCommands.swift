#if DEBUG
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// `supermux.devices.terminal_sizing.*` socket methods (DEBUG builds only):
/// E2E drivers for this Mac's terminal size preference
/// (`tests/supermux/loopback_terminal_sizing_policy_e2e.py`). Each runs the
/// same code path as its UI entry point. Routed from
/// ``SupermuxDevicesSocketCommands``.
///
/// - `state {}` — the stored preference and each device mirror's claim
///   (`null` where this build has none).
/// - `reset {}` — forgets the stored preference and applies the default.
/// - `select_mode {surface_id, mode, fixed_cols?, fixed_rows?}` — the size
///   panel's mode picker; with `fixed_cols`/`fixed_rows`, its fixed-size editor.
/// - `set_priority {surface_id, keys}` — the size panel's priority drag.
@MainActor
enum SupermuxTerminalSizingSocketCommands {
    static let methodPrefix = "terminal_sizing."

    static func handles(_ name: String) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle(_ name: String, params: [String: Any]) throws -> [String: Any] {
        switch name.dropFirst(methodPrefix.count) {
        case "state":
            return ["preference": NSNull(), "stored": NSNull(), "mirrors": NSNull()]
        case "reset":
            return ["reset": false]
        case "select_mode":
            return try selectMode(params)
        case "set_priority":
            return try setPriority(params)
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "unknown terminal_sizing method \(name)")
        }
    }

    // MARK: - Panel actions

    private static func selectMode(_ params: [String: Any]) throws -> [String: Any] {
        let surfaceID = try surfaceID(params)
        guard let mode = (params["mode"] as? String).flatMap(TerminalSizingMode.init(rawValue:)) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "mode must be one of latest, smallest, largest, priority, fixed")
        }
        let store = TerminalController.shared.terminalSharing
        let accepted: Bool
        if let cols = (params["fixed_cols"] as? NSNumber)?.intValue, let rows = (params["fixed_rows"] as? NSNumber)?.intValue {
            accepted = store.setFixedSize(TerminalGridSize(cols: cols, rows: rows), surfaceID: surfaceID)
        } else {
            accepted = store.setMode(mode, surfaceID: surfaceID)
        }
        return payload(surfaceID, accepted: accepted)
    }

    private static func setPriority(_ params: [String: Any]) throws -> [String: Any] {
        let surfaceID = try surfaceID(params)
        guard let keys = params["keys"] as? [String], !keys.isEmpty else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "keys must be a non-empty list of priority keys")
        }
        let accepted = TerminalController.shared.terminalSharing.setPriority(keys, surfaceID: surfaceID)
        return payload(surfaceID, accepted: accepted)
    }

    // MARK: - Helpers

    /// A local terminal gets its sizing host first, as opening its size panel does.
    private static func surfaceID(_ params: [String: Any]) throws -> UUID {
        let controller = TerminalController.shared
        guard let raw = params["surface_id"] as? String, let id = UUID(uuidString: raw) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id must be a terminal id")
        }
        if controller.terminalSharing.snapshot(for: id) == nil {
            _ = controller.localSizingHost(surfaceID: id, create: true)
        }
        guard controller.terminalSharing.snapshot(for: id) != nil else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id must name a terminal with a size state")
        }
        return id
    }

    private static func payload(_ surfaceID: UUID, accepted: Bool) -> [String: Any] {
        var payload = TerminalController.shared.sizeStatePayload(surfaceID: surfaceID)
        payload["accepted"] = accepted
        return payload
    }
}
#endif

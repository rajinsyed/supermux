#if DEBUG
import CmuxSidebar
import Foundation
import SupermuxKit

/// `supermux.devices.ports.*` socket methods (DEBUG builds only): E2E drivers
/// for forwarding another Mac's ports to this Mac
/// (`tests/supermux/loopback_port_forward_e2e.py`). Routed from
/// ``SupermuxDevicesSocketCommands``.
///
/// - `list {machine?}` — the forwards, each Mac's availability and port
///   listing, and what every device mirror shows (its sidebar port chips and
///   its `supermux.ports.*` pills).
/// - `forward`, `stop`, `resume {machine, port}` — the "Ports on <Mac>" menu's
///   Forward to This Mac / Stop Forwarding.
/// - `set_auto {enabled}` — the Settings toggle.
/// - `refresh {machine?}` — fetches the Macs' port listings now (a test hook
///   for ports injected on the host without a poke).
@MainActor
enum SupermuxDevicePortsSocketCommands {
    static let methodPrefix = "ports."

    static func handles(_ name: String) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle(_ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch name.dropFirst(methodPrefix.count) {
        case "list":
            return ["auto": NSNull(), "forwards": [Any](), "availability": [String: Any](),
                    "host_ports": [String: Any](), "mirrors": mirrors()]
        case "forward", "stop", "resume", "set_auto", "refresh":
            return ["applied": false]
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "unknown ports method \(name)")
        }
    }

    /// Every device mirror's sidebar port chips and port pills.
    private static func mirrors() -> [[String: Any]] {
        SupermuxComposition.deviceWorkspaceIndex.mirrors().map { mirror in
            let pills = mirror.workspace.statusEntries
                .filter { $0.key.hasPrefix("supermux.ports.") }
                .mapValues(\.value)
            return [
                "workspace_id": mirror.workspace.id.uuidString,
                "machine": mirror.ref.machineID,
                "remote_workspace_id": mirror.ref.workspaceID,
                "listening_ports": mirror.workspace.listeningPorts,
                "port_pills": pills,
            ]
        }
    }
}
#endif

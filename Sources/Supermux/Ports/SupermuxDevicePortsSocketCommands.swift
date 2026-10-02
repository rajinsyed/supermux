#if DEBUG
import CmuxSidebar
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// `supermux.devices.ports.*` socket methods (DEBUG builds only): E2E drivers
/// for forwarding another Mac's ports to this Mac
/// (`tests/supermux/loopback_port_forward_e2e.py`). Each runs the code path of
/// its UI entry point. Routed from ``SupermuxDevicesSocketCommands``.
///
/// - `list {machine?}` — the forwards, each Mac's availability and port
///   listing (`host_ports`, and `host_other_ports`: its `other_ports`, null
///   when the listing did not ask for them), and what every device mirror shows (its sidebar port chips and
///   its `supermux.ports.*` pills).
/// - `forward`, `stop`, `resume {machine, port}` — the "Ports on <Mac>" menu's
///   Forward to This Mac / Stop Forwarding.
/// - `set_auto {enabled}` — the Settings toggle (through the card's action).
/// - `refresh {machine?}` — fetches the Macs' port listings now (a test hook
///   for ports injected on the host without a poke).
@MainActor
enum SupermuxDevicePortsSocketCommands {
    static let methodPrefix = "ports."

    static func handles(_ name: String) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle(_ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        let forwards = SupermuxComposition.portForwards
        switch name.dropFirst(methodPrefix.count) {
        case "list":
            return list(machine: try optionalMachine(params))
        case "forward":
            let (machine, port) = try target(params)
            await forwards.forward(machine: machine, remotePort: port)
        case "stop":
            let (machine, port) = try target(params)
            await forwards.stop(machine: machine, remotePort: port)
        case "resume":
            let (machine, port) = try target(params)
            await forwards.resume(machine: machine, remotePort: port)
        case "set_auto":
            guard let enabled = params["enabled"] as? Bool else { throw invalid("enabled must be a boolean") }
            SupermuxComposition.remoteMacsSettings.actions().setForwardPorts(enabled)
        case "refresh":
            forwards.refresh(machine: try optionalMachine(params))
        default:
            throw invalid("unknown ports method \(name)")
        }
        return ["applied": true]
    }

    // MARK: - Payloads

    private static func list(machine: SurfaceMachineID?) -> [String: Any] {
        let forwards = SupermuxComposition.portForwards
        let mirrors = mirrors()
        let rows = forwards.forwards.values
            .filter { machine == nil || $0.key.machine == machine }
            .sorted { $0.key.description < $1.key.description }
            .map { forward -> [String: Any] in
                let pill = mirrors.lazy
                    .filter { $0["machine"] as? String == forward.key.machine.rawValue }
                    .compactMap { ($0["port_pills"] as? [String: String])?["supermux.ports.\(forward.key.remotePort)"] }
                    .first
                return [
                    "machine": forward.key.machine.rawValue,
                    "remote_port": forward.key.remotePort,
                    "local_port": forward.localPort ?? NSNull(),
                    "last_local_port": forward.lastLocalPort ?? NSNull(),
                    "origin": forward.origin.rawValue,
                    "state": stateName(forward.state),
                    "failure": failure(forward.state) ?? NSNull(),
                    "workspace_ids": forward.workspaceIDs,
                    "terminal_title": forward.terminalTitle ?? NSNull(),
                    "pill": pill ?? NSNull(),
                ]
            }
        var availability: [String: Any] = [:]
        for (key, value) in forwards.availability where machine == nil || key == machine {
            availability[key.rawValue] = value.rawValue
        }
        var hostPorts: [String: Any] = [:]
        var hostOtherPorts: [String: Any] = [:]
        for (key, listing) in forwards.hostPorts where machine == nil || key == machine {
            hostOtherPorts[key.rawValue] = listing.otherPorts ?? NSNull()
            hostPorts[key.rawValue] = listing.ports.map { port -> [String: Any] in
                [
                    "port": port.port,
                    "workspace_id": port.workspaceID,
                    "workspace_title": port.workspaceTitle ?? NSNull(),
                    "terminal_title": port.terminalTitle ?? NSNull(),
                ]
            }
        }
        return [
            "auto": SupermuxComposition.devicesSettings.forwardPorts,
            "forwards": rows,
            "availability": availability,
            "host_ports": hostPorts,
            "host_other_ports": hostOtherPorts,
            "mirrors": mirrors,
        ]
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

    private static func stateName(_ state: SupermuxPortForwards.State) -> String {
        switch state {
        case .starting: return "starting"
        case .active: return "active"
        case .stopped: return "stopped"
        case .waiting: return "waiting"
        case .failed: return "failed"
        }
    }

    private static func failure(_ state: SupermuxPortForwards.State) -> String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    // MARK: - Params

    private static func target(_ params: [String: Any]) throws -> (SurfaceMachineID, Int) {
        guard let machine = try optionalMachine(params) else { throw invalid("machine is required") }
        guard let port = (params["port"] as? NSNumber)?.intValue, (1...65_535).contains(port) else {
            throw invalid("port must be 1-65535")
        }
        return (machine, port)
    }

    private static func optionalMachine(_ params: [String: Any]) throws -> SurfaceMachineID? {
        guard let raw = params["machine"] as? String, !raw.isEmpty else { return nil }
        let machine = SurfaceMachineID(rawValue: raw)
        guard machine.isDevice else { throw invalid("machine must be a device id from supermux.devices.list") }
        return machine
    }

    private static func invalid(_ message: String) -> SupermuxMirrorSocketCommands.InvalidParams {
        SupermuxMirrorSocketCommands.InvalidParams(message: message)
    }
}
#endif

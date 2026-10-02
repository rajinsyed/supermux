#if DEBUG
import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation

/// DEBUG-only `supermux.devices.tunnel.*` drivers for
/// `tests/supermux/loopback_device_tunnel_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``. The loopback device's tunnel lanes run
/// the real `IrxTunnelHost` in-process (``SupermuxDeviceLoopbackHostAcceptor``):
///
/// - `tunnel.http_get {machine, host?, port, path?, timeout_seconds?}`: one HTTP/1.1
///   GET through a tunnel to `host:port` (default `localhost`) on that Mac's
///   loopback → `{status, http_status?, body?}`. `status` is `connected`, or
///   why the open failed (`denied`, `refused`, `busy`, `failed`, or the tunnel's
///   availability: `offline`, `needs_update`, `no_direct_link`).
/// - `tunnel.hold {machine, host?, port}`: opens a tunnel and keeps it open →
///   `{status, held}`; `tunnel.release_held {}` aborts every held tunnel.
/// - `tunnel.host_state {machine}`: the newest loopback connection's tunnel host
///   → `{has_tunnel_host, connection_live, active_tunnels}`.
/// - `tunnel.journal {}`: the loopback tunnel host's `host-tunnel` journal events.
/// - `tunnel.revoke {revoked}`: refuse every tunnel open, as for a revoked peer.
/// - `tunnel.pretend_old_host {enabled}`: this host stops advertising
///   `supermux.port_forward.v1`, as a host that predates port forwarding.
/// - `tunnel.inject_port {workspace_id, port}` / `tunnel.clear_injected {}`:
///   a port reported as that workspace's, without the live-listener check.
/// - `tunnel.host_ports {include_other?}`: this Mac's `ports.list` payload.
/// - `tunnel.own_port {port, registered}`: marks a port as one this app
///   listens on for forwards (the tunnel host's loop guard refuses it).
@MainActor
enum SupermuxDeviceTunnelSocketCommands {
    static let methodPrefix = "tunnel."

    /// Read by the nonisolated capability list (`SupermuxMobileCapabilities`).
    nonisolated(unsafe) static var pretendsOldHost = false
    /// Ports reported as a workspace's by `ports.list`, live or not.
    static var injectedHostPorts: [UUID: [Int]] = [:]

    private typealias Stream = any SupermuxByteStream
    private static var held: [Stream] = []
    /// Ports `own_port` registered, so it never unregisters a real listener's.
    private static var registeredByDriver: Set<Int> = []

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Whether `name` (the part after `supermux.devices.`) is one of these drivers.
    static func handles<S: StringProtocol>(_ name: S) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle<S: StringProtocol>(_ name: S, _ params: [String: Any]) async throws -> [String: Any] {
        switch String(name.dropFirst(methodPrefix.count)) {
        case "http_get": return try await httpGet(params)
        case "hold": return try await hold(params)
        case "release_held": return await releaseHeld()
        case "host_state": return try await hostState(params)
        case "journal": return journal()
        case "revoke":
            SupermuxDeviceLoopbackHostAcceptor.tunnelAuthorizationRevoked = try flag(params, "revoked")
            return ["revoked": SupermuxDeviceLoopbackHostAcceptor.tunnelAuthorizationRevoked]
        case "pretend_old_host":
            pretendsOldHost = try flag(params, "enabled")
            return ["enabled": pretendsOldHost]
        case "inject_port":
            let workspaceID = try uuid(params, "workspace_id")
            injectedHostPorts[workspaceID, default: []].append(try port(params))
            return ["injected": injectedHostPorts[workspaceID] ?? []]
        case "clear_injected":
            injectedHostPorts = [:]
            return ["injected": [Int]()]
        case "host_ports": return await hostPorts(params)
        case "own_port": return try ownPort(params)
        default: throw HookError(message: "unknown tunnel method \(name)")
        }
    }

    // MARK: - Tunnels

    /// One tunnel the way a forward or a mirror's browser opens it.
    private static func open(_ params: [String: Any]) async throws -> Stream {
        try await SupermuxDeviceTunnelClient.open(machine: try machine(params), host: host(params), port: try port(params))
    }

    private static func httpGet(_ params: [String: Any]) async throws -> [String: Any] {
        let targetPort = try port(params)
        let stream: Stream
        do {
            stream = try await open(params)
        } catch let error as HookError {
            throw error
        } catch {
            return ["status": status(of: error)]
        }
        let path = (params["path"] as? String) ?? "/"
        let seconds = min(max((params["timeout_seconds"] as? NSNumber)?.doubleValue ?? 10, 1), 60)
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host(params)):\(targetPort)\r\nConnection: close\r\n\r\n"
        let deadline = Task {
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            await stream.abort()
        }
        defer { deadline.cancel() }
        var response = Data()
        do {
            try await stream.write(Data(request.utf8))
            while response.count < 1 << 20, let chunk = try await stream.readRaw(maximumByteCount: 64 * 1024) {
                response.append(chunk)
            }
        } catch {
            return ["status": "connected", "error": "the tunnel ended early: \(error)", "received": response.count]
        }
        await stream.abort()
        var result = parse(response)
        result["status"] = "connected"
        return result
    }

    private static func hold(_ params: [String: Any]) async throws -> [String: Any] {
        do {
            held.append(try await open(params))
            return ["status": "connected", "held": held.count]
        } catch let error as HookError {
            throw error
        } catch {
            return ["status": status(of: error), "held": held.count]
        }
    }

    private static func releaseHeld() async -> [String: Any] {
        let streams = held
        held.removeAll()
        for stream in streams { await stream.abort() }
        return ["released": streams.count]
    }

    /// The tunnel failure as the suite names it: the host's answer
    /// (`IrxTunnelOpenReply.Status` names), or why no tunnel could be opened.
    private static func status(of error: any Error) -> String {
        guard let failure = error as? SupermuxDeviceTunnelClient.Failure else {
            return IrxTunnelOpenReply.Status.failed.rawValue
        }
        switch failure {
        case .unavailable(let availability): return availability.rawValue
        case .notListening: return IrxTunnelOpenReply.Status.refused.rawValue
        case .denied: return IrxTunnelOpenReply.Status.denied.rawValue
        case .busy: return IrxTunnelOpenReply.Status.busy.rawValue
        case .failed: return IrxTunnelOpenReply.Status.failed.rawValue
        }
    }

    /// `{http_status, body}` of a whole HTTP/1.x response (the suite's
    /// servers answer `Connection: close` with a plain body).
    private static func parse(_ response: Data) -> [String: Any] {
        let text = String(decoding: response, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else { return ["http_status": NSNull(), "body": text] }
        let statusLine = text[..<split.lowerBound].split(separator: "\r\n").first ?? ""
        let code = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        return ["http_status": code ?? NSNull(), "body": String(text[split.upperBound...])]
    }

    // MARK: - Host

    private static func hostState(_ params: [String: Any]) async throws -> [String: Any] {
        guard let acceptor = SupermuxDeviceLoopbackHarness.tunnelAcceptor(for: try machine(params)) else {
            throw HookError(message: "machine is not the loopback device")
        }
        let state = await acceptor.tunnelHostState()
        return [
            "has_tunnel_host": state.hasHost,
            "connection_live": state.connectionLive,
            "active_tunnels": state.activeTunnels,
        ]
    }

    private static func journal() -> [String: Any] {
        let events = SupermuxDeviceLoopbackHostAcceptor.tunnelJournal.tail(200)
            .filter { $0.component == "host-tunnel" }
            .map { ["event": $0.event, "attributes": $0.attributes] as [String: Any] }
        return ["events": events]
    }

    /// This Mac's own `ports.list` payload, built locally.
    private static func hostPorts(_ params: [String: Any]) async -> [String: Any] {
        let list = await SupermuxHostPorts.list(includeOther: params["include_other"] as? Bool == true)
        guard let data = try? JSONEncoder().encode(list),
              let object = try? JSONSerialization.jsonObject(with: data) else { return ["ports": NSNull()] }
        return ["ports": object]
    }

    /// Registers a port at most once and unregisters only what it registered,
    /// so the suite's cleanup never frees a real forward's port.
    private static func ownPort(_ params: [String: Any]) throws -> [String: Any] {
        let target = try port(params)
        let ports = SupermuxOwnListenerPorts.shared
        if try flag(params, "registered") {
            if registeredByDriver.insert(target).inserted { ports.insert(target) }
        } else if registeredByDriver.remove(target) != nil {
            ports.remove(target)
        }
        return ["registered": ports.contains(target)]
    }

    // MARK: - Params

    private static func machine(_ params: [String: Any]) throws -> SurfaceMachineID {
        guard let raw = params["machine"] as? String, SurfaceMachineID(rawValue: raw).isDevice else {
            throw HookError(message: "machine must be a device id from supermux.devices.list")
        }
        return SurfaceMachineID(rawValue: raw)
    }

    private static func host(_ params: [String: Any]) -> String {
        (params["host"] as? String) ?? "localhost"
    }

    private static func port(_ params: [String: Any]) throws -> Int {
        guard let port = (params["port"] as? NSNumber)?.intValue, (1...65_535).contains(port) else {
            throw HookError(message: "port must be 1-65535")
        }
        return port
    }

    private static func uuid(_ params: [String: Any], _ key: String) throws -> UUID {
        guard let raw = params[key] as? String, let id = UUID(uuidString: raw) else {
            throw HookError(message: "\(key) must be a UUID")
        }
        return id
    }

    private static func flag(_ params: [String: Any], _ key: String) throws -> Bool {
        guard let value = params[key] as? Bool else { throw HookError(message: "\(key) must be true or false") }
        return value
    }
}
#endif

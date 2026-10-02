#if DEBUG
import CmuxIrxTransport
import CmuxSettings
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
///   availability: `offline`, `needs_update`, `no_direct_link`, …); a failed
///   open also answers what a mirror's browser would show for it
///   (`page_reason`, `page_headline` of ``SupermuxBrowserProxyErrorPage``).
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
/// - `tunnel.inject_other_port {port, remove?}`: a port `ports.list` reports under
///   `other_ports` when asked for them (a server this Mac runs outside its
///   workspaces' terminals: started by an agent, orphaned, in Docker), without
///   the live-listener check (`remove: true` takes it back); `clear_injected`
///   clears these too.
/// - `tunnel.host_ports {include_other?}`: this Mac's `ports.list` payload.
/// - `tunnel.listings_served {}`: how many `mobile.supermux.ports.list` requests
///   this Mac's host answered since launch → `{count}`.
/// - `tunnel.own_port {port, registered}`: marks a port as one this app
///   listens on for forwards (the tunnel host's loop guard refuses it).
/// - `tunnel.serve_port {port, from?}`: the loopback owner's tunnel host serves
///   its `port` from this machine's `from` (as itself again without `from`),
///   so `port` stays free here and a forward of it can listen on it
///   (``SupermuxLoopbackServedPorts``) → `{port, from}`.
/// - `tunnel.fail_requests {method, count?}`: the loopback host answers the
///   next `count` requests for `method` (after each connection's sync fetch)
///   `timed_out`, as a stalled Mac does (0 disarms; arming restarts the tally)
///   → `{method, remaining, failed}`; without `count` it only reports.
/// - `tunnel.allow_other_hosts {enabled?}`: turns this build's iPhone-labelled
///   `mobile.browserTunnel.allowOtherHosts` on; off puts back what was stored
///   before the driver turned it on; without `enabled` it changes nothing
///   → `{enabled}` (the setting's value now).
@MainActor
enum SupermuxDeviceTunnelSocketCommands {
    static let methodPrefix = "tunnel."

    /// Read by the nonisolated capability list (`SupermuxMobileCapabilities`).
    nonisolated(unsafe) static var pretendsOldHost = false
    /// Ports reported as a workspace's by `ports.list`, live or not.
    static var injectedHostPorts: [UUID: [Int]] = [:]
    /// Ports reported under `other_ports` by `ports.list`, live or not.
    static var injectedOtherPorts: Set<Int> = []
    /// `mobile.supermux.ports.list` requests the host answered.
    nonisolated static let listingsServed = SupermuxDebugCounter()

    private typealias Stream = any SupermuxByteStream
    private static var held: [Stream] = []
    /// Ports `own_port` registered, so it never unregisters a real listener's.
    private static var registeredByDriver: Set<Int> = []

    /// A setting's stored value (nil: none was stored) before a driver changed it.
    private struct SavedSetting {
        let stored: Bool?
    }

    /// `allowOtherHosts` before `allow_other_hosts` turned it on; nil while the
    /// driver has not changed it, so turning it off never touches a user's value.
    private static var allowOtherHostsSaved: SavedSetting?

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
        case "allow_other_hosts": return try allowOtherHosts(params)
        case "inject_port":
            let workspaceID = try uuid(params, "workspace_id")
            injectedHostPorts[workspaceID, default: []].append(try port(params))
            return ["injected": injectedHostPorts[workspaceID] ?? []]
        case "inject_other_port":
            if params["remove"] as? Bool == true {
                injectedOtherPorts.remove(try port(params))
            } else {
                injectedOtherPorts.insert(try port(params))
            }
            return ["injected_other": injectedOtherPorts.sorted()]
        case "clear_injected":
            injectedHostPorts = [:]
            injectedOtherPorts = []
            return ["injected": [Int]()]
        case "host_ports": return await hostPorts(params)
        case "listings_served": return ["count": listingsServed.value]
        case "own_port": return try ownPort(params)
        case "serve_port": return try servePort(params)
        case "fail_requests": return try failRequests(params)
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
            let reason = SupermuxBrowserProxyErrorPage.Reason(error)
            let name = SupermuxComposition.devices.device(for: try machine(params))?.displayName ?? ""
            return [
                "status": status(of: error),
                "page_reason": reason.rawValue,
                "page_headline": SupermuxBrowserProxyErrorPage.headline(reason: reason, machineName: name, port: targetPort),
            ]
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
        // The server closed its side (`Connection: close`): close ours too,
        // so the host's relay ends clean.
        await stream.finish()
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

    private static func servePort(_ params: [String: Any]) throws -> [String: Any] {
        let target = try port(params)
        var source: Int?
        if let from = params["from"] as? NSNumber { source = try port(["port": from]) }
        SupermuxLoopbackServedPorts.shared.serve(target, from: source)
        return ["port": target, "from": source ?? NSNull()]
    }

    /// Arms (or, without `count`, only reports) the loopback host's failed
    /// answers for one method (``SupermuxDeviceLoopbackHostAcceptor/failingRequests``).
    private static func failRequests(_ params: [String: Any]) throws -> [String: Any] {
        guard let method = params["method"] as? String, !method.isEmpty else {
            throw HookError(message: "method is required")
        }
        if let count = (params["count"] as? NSNumber)?.intValue {
            SupermuxDeviceLoopbackHostAcceptor.failingRequests[method] = max(count, 0)
            SupermuxDeviceLoopbackHostAcceptor.failedRequests[method] = 0
        }
        return [
            "method": method,
            "remaining": SupermuxDeviceLoopbackHostAcceptor.failingRequests[method] ?? 0,
            "failed": SupermuxDeviceLoopbackHostAcceptor.failedRequests[method] ?? 0,
        ]
    }

    /// Turns "iOS Browser Reaches Other Hosts" on, which must not widen what
    /// another Mac reaches (``SupermuxDeviceTunnelHosts``). Off puts back the
    /// value stored before (or none), and does nothing unless this turned it on.
    /// Without `enabled` it only reports the value (a cmux.json that manages
    /// the key puts its own value back after every defaults change).
    private static func allowOtherHosts(_ params: [String: Any]) throws -> [String: Any] {
        let key = SettingCatalog().mobile.browserTunnelAllowOtherHosts
        let defaults = UserDefaults.standard
        guard params["enabled"] != nil else { return ["enabled": key.value(in: defaults)] }
        if try flag(params, "enabled") {
            if allowOtherHostsSaved == nil {
                allowOtherHostsSaved = SavedSetting(stored: key.hasStoredValue(in: defaults) ? key.value(in: defaults) : nil)
            }
            key.set(true, in: defaults)
        } else if let saved = allowOtherHostsSaved {
            allowOtherHostsSaved = nil
            if let stored = saved.stored {
                key.set(stored, in: defaults)
            } else {
                key.removeValue(in: defaults)
            }
        }
        return ["enabled": key.value(in: defaults)]
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
/// A thread-safe count (DEBUG E2E evidence).
final class SupermuxDebugCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
#endif

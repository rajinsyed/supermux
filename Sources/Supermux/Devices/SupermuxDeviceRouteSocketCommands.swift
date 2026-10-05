#if DEBUG
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// DEBUG-only `supermux.devices.route.*` drivers for
/// `tests/supermux/loopback_device_route_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``. The loopback device has no Iroh
/// connection, so its route is pinned here and goes through the same publish
/// rule as a real sample; its route-candidates request runs for real.
///
/// - `route.override {machine, kind: direct|relay|clear, scope?, relay_id?, rtt_ms?}`:
///   pins (or with `clear` unpins) the link's sampled route → `{route}`.
/// - `route.sample {}`: one sampling pass now (also asks due candidates)
///   → `{routes: {machine: route}}`.
/// - `route.candidates_serve {addresses?, endpoint_id?, refuse?}`: this host
///   answers `route.candidates` with these (the servable filter still
///   applies), or refuses with `refuse` (`not_ready`: no address yet;
///   `direct_off`: relay-only, the asker forgets the peer); with neither it
///   serves its real endpoint again → `{pinned}`.
/// - `route.candidates_fetch {machine}`: asks that Mac for its addresses now
///   → `{outcome}` (`stored`, `empty`, `not_ready`, `direct_off`, `failed`, …).
/// - `route.candidates {}`: the cache → `{file, peers: [{device_id, tag,
///   endpoint_id, dial_addresses, candidates}], fetches_stored, served_count}`.
/// - `route.switch {machine, active?, lane?: open|blocked, reset?}`: the
///   simulated network under the loopback link (``SupermuxRouteSwitchSimulation``);
///   `reset` forgets the link's switch policy, counters and landings; turning
///   it off unpins the route → the status below.
/// - `route.switch_status {machine}` → `{active, lane_open, landings: [{at_ms,
///   direct}], policy: {session, flaps, probe_failures, allows_direct,
///   hold_off_ms}, stats: {probes, probe_successes, checks, misses, upgrades,
///   fallbacks}}`.
/// - `route.probe_now {reason?}`: the wake / network-change hook
///   (``SupermuxDeviceRouteSwitcher/probeNow(reason:)``: hold-off cleared,
///   probe now) → `{}`.
@MainActor
enum SupermuxDeviceRouteSocketCommands {
    static let methodPrefix = "route."

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
        case "override": return try override(params)
        case "sample":
            await SupermuxComposition.deviceRouteMonitor.sampleNow()
            return ["routes": routes()]
        case "candidates_serve": return try serve(params)
        case "candidates_fetch":
            let outcome = await SupermuxComposition.routeCandidateSync.fetch(try device(params))
            return ["outcome": outcome.rawValue]
        case "candidates": return await candidates()
        case "switch": return try simulate(params)
        case "switch_status": return switchStatus(try device(params))
        case "probe_now":
            SupermuxComposition.routeSwitcher.probeNow(reason: params["reason"] as? String ?? "debug")
            return [:]
        default: throw HookError(message: "unknown route method \(name)")
        }
    }

    private static func override(_ params: [String: Any]) throws -> [String: Any] {
        let device = try device(params)
        let rtt = params["rtt_ms"] as? Int
        let kind: SupermuxLinkRoute.Kind?
        switch params["kind"] as? String {
        case "direct":
            guard let scope = (params["scope"] as? String).flatMap(SupermuxLinkRoute.Scope.init(rawValue:)) else {
                throw HookError(message: "direct needs scope lan|tailscale|internet")
            }
            kind = .direct(scope)
        case "relay": kind = .relay(id: (params["relay_id"] as? String)?.lowercased())
        case "clear": kind = nil
        default: throw HookError(message: "kind must be direct, relay or clear")
        }
        let route = kind.map { SupermuxLinkRoute(kind: $0, rttMs: rtt, since: Date()) }
        SupermuxComposition.deviceRouteMonitor.pin(route, for: device.instance)
        return ["route": SupermuxDevicesSocketPayloads.route(SupermuxComposition.deviceRoutes.route(for: device))]
    }

    private static func serve(_ params: [String: Any]) throws -> [String: Any] {
        if let refusal = params["refuse"] as? String {
            let codes = [SupermuxRouteCandidates.notReadyErrorCode, SupermuxRouteCandidates.directOffErrorCode]
            guard codes.contains(refusal) else { throw HookError(message: "refuse must be not_ready or direct_off") }
            SupermuxRouteCandidatesHost.pinRefusal(code: refusal)
            return ["pinned": true]
        }
        guard let addresses = params["addresses"] as? [String] else {
            SupermuxRouteCandidatesHost.pinAnswer(nil)
            return ["pinned": false]
        }
        SupermuxRouteCandidatesHost.pinAnswer(
            SupermuxRouteCandidatesDTO(endpointID: params["endpoint_id"] as? String, addresses: addresses))
        return ["pinned": true]
    }

    private static func candidates() async -> [String: Any] {
        let store = SupermuxComposition.routeCandidateStore
        var peers: [[String: Any]] = []
        for peer in await store.peers() {
            peers.append([
                "device_id": peer.key.deviceID,
                "tag": peer.key.tag,
                "endpoint_id": peer.key.endpointID,
                "dial_addresses": await store.dialAddresses(for: peer.key),
                "candidates": peer.candidates.map { ["address": $0.address, "source": $0.source.rawValue] },
            ])
        }
        return [
            "file": store.fileURL?.path ?? NSNull(),
            "peers": peers,
            "fetches_stored": SupermuxComposition.routeCandidateSync.storedCount,
            "served_count": SupermuxRouteCandidatesHost.servedCount,
        ]
    }

    private static func simulate(_ params: [String: Any]) throws -> [String: Any] {
        let device = try device(params)
        guard device.isLoopback else { throw HookError(message: "only the loopback link can be simulated") }
        let simulation = SupermuxRouteSwitchSimulation.shared
        if params["reset"] as? Bool == true {
            SupermuxComposition.routeSwitcher.reset(device.instance)
            simulation.clearLandings()
        }
        switch params["lane"] as? String {
        case "open": simulation.laneOpen = true
        case "blocked": simulation.laneOpen = false
        case nil: break
        default: throw HookError(message: "lane must be open or blocked")
        }
        if let active = params["active"] as? Bool {
            simulation.activate(active)
            if !active {
                SupermuxComposition.routeSwitcher.reset(device.instance)
                SupermuxComposition.deviceRouteMonitor.pin(nil, for: device.instance)
            }
        }
        return switchStatus(device)
    }

    private static func switchStatus(_ device: SupermuxDevice) -> [String: Any] {
        let simulation = SupermuxRouteSwitchSimulation.shared
        let switcher = SupermuxComposition.routeSwitcher
        let stats = switcher.stats[device.instance] ?? SupermuxDeviceRouteSwitcher.Stats()
        var policy: [String: Any] = ["allows_direct": switcher.allowsDirect(device.instance)]
        if let current = switcher.policy(for: device.instance) {
            policy["session"] = current.session
            policy["flaps"] = current.flaps
            policy["probe_failures"] = current.probeFailures
            policy["hold_off_ms"] = current.holdOffUntil.map { max(0, Int($0.timeIntervalSinceNow * 1_000)) } ?? 0
        }
        return [
            "active": simulation.isActive,
            "lane_open": simulation.laneOpen,
            "landings": simulation.landings.map {
                ["at_ms": Int($0.at.timeIntervalSince1970 * 1_000), "direct": $0.direct] as [String: Any]
            },
            "policy": policy,
            "stats": [
                "probes": stats.probes, "probe_successes": stats.probeSuccesses, "checks": stats.checks,
                "misses": stats.misses, "upgrades": stats.upgrades, "fallbacks": stats.fallbacks,
            ],
        ]
    }

    private static func routes() -> [String: Any] {
        var result: [String: Any] = [:]
        for device in SupermuxComposition.devices.devices {
            result[device.machine.rawValue] = SupermuxDevicesSocketPayloads.route(
                SupermuxComposition.deviceRoutes.route(for: device))
        }
        return result
    }

    private static func device(_ params: [String: Any]) throws -> SupermuxDevice {
        guard let raw = params["machine"] as? String,
              let device = SupermuxComposition.devices.device(for: SurfaceMachineID(rawValue: raw)) else {
            throw HookError(message: "unknown machine")
        }
        return device
    }
}
#endif

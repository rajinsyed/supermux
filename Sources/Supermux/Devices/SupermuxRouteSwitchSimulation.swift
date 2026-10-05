#if DEBUG
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// DEBUG-only: a simulated network under the loopback device's link, so the
/// route switcher's real policy, its planned redials and fall backs, and the
/// link's real reconnects run end to end
/// (`tests/supermux/loopback_device_route_switch_e2e.py`, through
/// `supermux.devices.route.switch`). The loopback link has no Iroh session.
///
/// While on, each new session of the loopback link lands like the dial's
/// race: direct (no relay path beside it) when the lane is open, the link's
/// policy allows direct and the route-candidate cache holds an address for
/// the peer; otherwise on the relay. A probe answers, and a direct session
/// answers its liveness checks, only while the lane is open. Each landing is
/// pinned as the link's route, so `supermux.devices.list` reports it.
@MainActor
final class SupermuxRouteSwitchSimulation {
    static let shared = SupermuxRouteSwitchSimulation()

    /// One session's landing.
    struct Landing {
        let at: Date
        let direct: Bool
    }

    private(set) var isActive = false
    /// Whether the simulated direct path works.
    var laneOpen = true
    /// Every simulated session's landing since the last reset, oldest first.
    private(set) var landings: [Landing] = []

    func activate(_ active: Bool) {
        isActive = active
        if !active { laneOpen = true }
    }

    func clearLandings() {
        landings = []
    }

    /// The loopback link's simulated session; nil while the simulation is off.
    func session(for device: SupermuxDevice) async -> (any SupermuxRouteSwitchLinkSession)? {
        guard isActive else { return nil }
        let hasAddresses = await Self.hasDirectAddresses(device.instance)
        guard isActive else { return nil }
        let direct = laneOpen && hasAddresses && SupermuxComposition.routeSwitcher.allowsDirect(device.instance)
        landings.append(Landing(at: Date(), direct: direct))
        let route = direct
            ? SupermuxLinkRoute(kind: .direct(.lan), rttMs: 6, since: Date())
            : SupermuxLinkRoute(kind: .relay(id: "apne1"), rttMs: 241, since: Date())
        SupermuxComposition.deviceRouteMonitor.pin(route, for: device.instance)
        return SupermuxSimulatedRouteSwitchSession(direct: direct, instance: device.instance, simulation: self)
    }

    /// Whether the route-candidate cache holds a direct address for the peer (the race and probes need one).
    static func hasDirectAddresses(_ instance: SurfaceDeviceInstanceID) async -> Bool {
        let store = SupermuxComposition.routeCandidateStore
        for peer in await store.peers() where peer.key.deviceID == instance.deviceID && peer.key.tag == instance.tag {
            if await !store.dialAddresses(for: peer.key).isEmpty { return true }
        }
        return false
    }
}

/// A simulated session of the loopback link.
@MainActor
final class SupermuxSimulatedRouteSwitchSession: SupermuxRouteSwitchLinkSession {
    let path: SupermuxRouteSwitchPolicy.Path?
    private let instance: SurfaceDeviceInstanceID
    private let simulation: SupermuxRouteSwitchSimulation

    init(direct: Bool, instance: SurfaceDeviceInstanceID, simulation: SupermuxRouteSwitchSimulation) {
        path = direct ? .direct(backedUp: false) : .relay
        self.instance = instance
        self.simulation = simulation
    }

    /// Like the lane's probe: it needs an address to dial and an open path.
    func probeDirect() async -> Duration? {
        try? await Task.sleep(for: .milliseconds(50))
        guard await SupermuxRouteSwitchSimulation.hasDirectAddresses(instance) else { return nil }
        return simulation.laneOpen ? .milliseconds(5) : nil
    }

    func answers() async -> Bool {
        simulation.laneOpen
    }
}
#endif

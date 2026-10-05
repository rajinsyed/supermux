import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// App-wide instances for the route each remote Mac's link uses, the
/// direct addresses this Mac dials them at, and the direct lane it dials on.
@MainActor
extension SupermuxComposition {
    /// Each connected Mac's published route (direct LAN / Tailscale /
    /// Internet, or a relay's place, with iroh's RTT): what UI shows.
    /// Nonisolated so `cmux iroh-diag` reaches its ``SupermuxDeviceRoutes/offMainRoutes``
    /// without the main actor; everything else on it is main-actor isolated.
    nonisolated static let deviceRoutes = SupermuxDeviceRoutes(journal: MobileHostIrxRuntime.journal)

    /// ``deviceRoutes`` by catalog machine id, for the SupermuxKit views that
    /// show a Mac's route (the Mac icon on a nested row, the presets bar's
    /// host mark, the Changes strip); nil while that Mac is not connected.
    static let linkRouteLookup = SupermuxLinkRouteLookup { machineID in
        devices.device(for: SurfaceMachineID(rawValue: machineID)).flatMap { deviceRoutes.route(for: $0) }
    }

    /// Other devices' direct addresses, read by the dialer off the main actor.
    nonisolated static let routeCandidateStore = SupermuxRouteCandidateStore(
        fileURL: SupermuxPaths.routeCandidatesFileURL)

    /// Asks connected Macs for their direct addresses.
    static let routeCandidateSync = SupermuxRouteCandidateSync(
        devices: devices,
        store: routeCandidateStore,
        sessionEndpointID: { instance in
            await SupermuxDeviceRouteMonitor.outgoingConnection(to: instance)?.remoteEndpointIDHex
        }
    )

    /// This Mac's direct lane: the dial's direct leg and the route probes, used off the main actor.
    nonisolated static let directLane = SupermuxDeviceDirectLane(journal: MobileHostIrxRuntime.journal)

    /// Moves each link between the direct lane and the relay.
    static let routeSwitcher = SupermuxDeviceRouteSwitcher(
        devices: devices,
        journal: MobileHostIrxRuntime.journal,
        session: { device in await SupermuxDeviceRouteSwitcher.liveSession(for: device) }
    )

    /// Samples each connected link's path into ``deviceRoutes``.
    static let deviceRouteMonitor = SupermuxDeviceRouteMonitor(
        devices: devices,
        routes: deviceRoutes,
        store: routeCandidateStore,
        sync: routeCandidateSync,
        path: { instance in await SupermuxDeviceRouteMonitor.outgoingPath(to: instance) }
    )
}

import Foundation
import SupermuxKit
import SupermuxMobileCore

/// App-wide instances for the route each remote Mac's link uses and the
/// direct addresses this Mac dials them at.
@MainActor
extension SupermuxComposition {
    /// Each connected Mac's published route (direct LAN / Tailscale /
    /// Internet, or a relay's place, with iroh's RTT): what UI shows.
    static let deviceRoutes = SupermuxDeviceRoutes(journal: MobileHostIrxRuntime.journal)

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

    /// Samples each connected link's path into ``deviceRoutes``.
    static let deviceRouteMonitor = SupermuxDeviceRouteMonitor(
        devices: devices,
        routes: deviceRoutes,
        store: routeCandidateStore,
        sync: routeCandidateSync,
        path: { instance in await SupermuxDeviceRouteMonitor.outgoingPath(to: instance) }
    )
}

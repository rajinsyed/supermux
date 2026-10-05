import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The direct addresses a dial to another Mac passes iroh (the
/// `route-dial-candidates` fence in `DeviceIrxClient.dial`; upstream passes
/// none): what that Mac handed over and what earlier outgoing sessions to it
/// used (``SupermuxComposition/routeCandidateStore``).
///
/// iroh sends a new dial's first packets to these as well as the relay, so
/// when its per-peer state has no selected path yet (a cold start, or after
/// both directions' sessions ended) the session can start on the LAN or
/// Tailscale instead of the relay. With a path already selected iroh uses
/// that one alone, so they change nothing then. None in relay-only mode, and
/// none when `supermux.route.dialCandidates` is false (on by default).
enum SupermuxRouteDialCandidates {
    /// The kill switch's defaults key.
    static let enabledDefaultsKey = "supermux.route.dialCandidates"

    /// The addresses for a dial to `instance` at `endpointID`.
    static func addresses(
        for instance: SurfaceDeviceInstanceID,
        endpointID: String,
        allowsDirectPaths: Bool,
        journal: IrxJournal
    ) async -> [String] {
        guard allowsDirectPaths, UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true else {
            return []
        }
        let key = SupermuxRoutePeerKey(deviceID: instance.deviceID, tag: instance.tag, endpointID: endpointID)
        let addresses = await SupermuxComposition.routeCandidateStore.dialAddresses(for: key)
        let scopes = addresses.compactMap { SupermuxSocketAddress($0)?.routeScope.rawValue }
        journal.record("route", "dial-candidates", [
            "device": String(instance.deviceID.prefix(8)),
            "count": String(addresses.count),
            "scopes": Set(scopes).sorted().joined(separator: ","),
        ])
        return addresses
    }
}

import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The direct addresses a dial to another Mac tries on the direct lane
/// (``SupermuxDeviceDirectDial``): what that Mac handed over and what earlier
/// outgoing sessions to it used (``SupermuxComposition/routeCandidateStore``).
///
/// They go to the direct lane only, never to the shared host endpoint: there
/// iroh sends a new dial's first packets to the path its per-peer state
/// already selected (usually the relay), and a session that did start direct
/// had no relay path to fall back to. None in relay-only mode, and none when
/// `supermux.route.dialCandidates` is false (on by default), which turns the
/// direct lane off entirely: every dial is upstream's relay dial.
enum SupermuxRouteDialCandidates {
    /// The kill switch's defaults key.
    static let enabledDefaultsKey = "supermux.route.dialCandidates"

    /// Whether the kill switch leaves the direct lane on.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The addresses for a dial to `instance` at `endpointID`.
    static func addresses(
        for instance: SurfaceDeviceInstanceID,
        endpointID: String,
        allowsDirectPaths: Bool,
        journal: IrxJournal
    ) async -> [String] {
        guard allowsDirectPaths, isEnabled else { return [] }
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

/// A dial to another Mac, direct first (the `route-dial-candidates` fence in
/// `DeviceIrxClient.dial`; upstream dials the relay alone): the direct lane
/// at the peer's direct addresses races upstream's relay dial on the shared
/// endpoint (``SupermuxIrxDirectFirstDial``). Direct wins whenever it connects
/// within 1.5 s; the relay is used only when no direct address answers.
///
/// The lane is skipped in relay-only mode, with the kill switch off, while
/// the link's switch policy holds direct off after a flap
/// (``SupermuxDeviceRouteSwitcher/allowsDirect(_:)``), and when the peer's
/// direct addresses are unknown. Journals `route/dial-race` with what each
/// leg did.
enum SupermuxDeviceDirectDial {
    static func connect(
        instance: SurfaceDeviceInstanceID,
        endpointID: String,
        relayURL: String,
        credentials: [IrxRelayCredential],
        main: IrxEndpointSupervisor,
        allowsDirectPaths: Bool,
        journal: IrxJournal
    ) async throws -> (connection: IrxConnection, leg: SupermuxIrxDialLeg) {
        let relayAddress = try main.dialAddress(peerEndpointIDHex: endpointID, relayURL: relayURL, directAddresses: [])
        var lane: IrxEndpointSupervisor?
        var addresses: [String] = []
        var skipped: String?
        if !allowsDirectPaths || !SupermuxRouteDialCandidates.isEnabled {
            skipped = "off"
        } else {
            lane = await SupermuxComposition.directLane.supervisor(matching: main)
            if await !SupermuxComposition.routeSwitcher.allowsDirect(instance) {
                skipped = "hold-off"
            } else {
                addresses = await SupermuxRouteDialCandidates.addresses(
                    for: instance, endpointID: endpointID, allowsDirectPaths: allowsDirectPaths, journal: journal)
                if addresses.isEmpty { skipped = "no-addresses" }
            }
        }
        var fields = ["device": String(instance.deviceID.prefix(8)), "candidates": String(addresses.count)]
        fields["direct_skipped"] = skipped
        do {
            let outcome = try await SupermuxIrxDirectFirstDial.dial(
                lane: skipped == nil ? lane : nil, directAddresses: addresses,
                main: main, relayAddress: relayAddress, credentials: credentials)
            if outcome.leg == .direct { await SupermuxComposition.directLane.adopt(outcome.value) }
            journal.record("route", "dial-race", fields.merging(outcome.journalFields) { $1 })
            return (outcome.value, outcome.leg)
        } catch {
            fields["error"] = String(describing: error).prefix(120).description
            journal.record("route", "dial-race-failed", fields)
            throw error
        }
    }
}

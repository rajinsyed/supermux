import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The direct addresses a dial to another Mac tries on the direct lane
/// (``SupermuxDeviceDirectDial``) and a route probe tries
/// (``SupermuxDeviceRouteSwitcher``): what that Mac handed over and what
/// earlier outgoing sessions to it used
/// (``SupermuxComposition/routeCandidateStore``), less those this Mac cannot
/// reach from its interfaces now (``SupermuxRouteCandidates/reachable(_:from:)``:
/// its own addresses, LAN on a subnet it is not on, Tailscale with its tunnel
/// down, global IPv6 with none of its own).
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

    /// The addresses of `key` this Mac can reach now, and how many were cached.
    static func reachable(for key: SupermuxRoutePeerKey) async -> (addresses: [String], cached: Int) {
        let cached = await SupermuxComposition.routeCandidateStore.dialAddresses(for: key)
        return (SupermuxRouteCandidates.reachable(cached, from: SupermuxLocalInterface.current()), cached.count)
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
        let (addresses, cached) = await reachable(for: key)
        let scopes = addresses.compactMap { SupermuxSocketAddress($0)?.routeScope.rawValue }
        journal.record("route", "dial-candidates", [
            "device": String(instance.deviceID.prefix(8)),
            "cached": String(cached),
            "count": String(addresses.count),
            "scopes": Set(scopes).sorted().joined(separator: ","),
        ])
        return addresses
    }
}

/// A dial to another Mac, direct first (the `route-dial-candidates` fence in
/// `DeviceIrxClient.dial`; upstream dials the relay alone): the direct lane
/// at the peer's reachable direct addresses, each its own handshake, races
/// upstream's relay dial on the shared endpoint (``SupermuxIrxDirectFirstDial``).
/// Direct wins whenever it connects within 1.5 s; the relay is used only when
/// no direct address answers. Where direct keeps losing on this network the
/// race stops holding a relay that is ready first
/// (``SupermuxDeviceRouteSwitcher/holdsRelayInRace(_:)``). With no relay
/// credential (an internet outage; the `route-lane-without-relay` fence lets
/// the dial through) only the lane can connect, so the LAN and Tailscale
/// still work.
///
/// The lane is skipped in relay-only mode, with the kill switch off, while
/// the link's switch policy holds direct off after a flap or skips it once
/// after a lane admission failed (``SupermuxDeviceRouteSwitcher/dialUsesDirect(_:)``),
/// and when none of the peer's direct addresses is reachable. Journals
/// `route/dial-race` with what each leg did.
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
        let directLane = SupermuxComposition.directLane
        var lane: IrxEndpointSupervisor?
        var addresses: [String] = []
        var skipped: String?
        if !allowsDirectPaths || !SupermuxRouteDialCandidates.isEnabled {
            skipped = "off"
        } else if await !SupermuxComposition.routeSwitcher.dialUsesDirect(instance) {
            skipped = "hold-off"
        } else {
            addresses = await SupermuxRouteDialCandidates.addresses(
                for: instance, endpointID: endpointID, allowsDirectPaths: allowsDirectPaths, journal: journal)
            if addresses.isEmpty { skipped = "no-addresses" }
        }
        if skipped == nil { lane = await directLane.beginUse(matching: main) }
        let holdsRelay = await SupermuxComposition.routeSwitcher.holdsRelayInRace(instance)
        var fields = ["device": String(instance.deviceID.prefix(8)), "candidates": String(addresses.count)]
        fields["direct_skipped"] = skipped
        if !holdsRelay { fields["holds_relay"] = "false" }
        do {
            let direct = lane.flatMap {
                SupermuxIrxDirectFirstDial.laneLeg(lane: $0, peerEndpointIDHex: endpointID, addresses: addresses)
            }
            let outcome = try await SupermuxIrxDirectFirstDial.race(
                timing: holdsRelay ? .standard : .noRelayHold, direct: direct,
                relay: {
                    // No relay credential (an internet outage): only the lane can connect; upstream's error otherwise.
                    guard !credentials.isEmpty else { throw DeviceLinkError.notConnected }
                    return try await main.dial(address: relayAddress, credentials: credentials)
                },
                discard: { await $0.close(code: .explicitRedial, origin: .local) })
            if lane != nil {
                if outcome.leg == .direct { await directLane.adopt(outcome.value) }
                await directLane.endUse()
                await SupermuxComposition.routeSwitcher.raceFinished(instance, directWon: outcome.leg == .direct)
            }
            journal.record("route", "dial-race", fields.merging(outcome.journalFields) { $1 })
            return (outcome.value, outcome.leg)
        } catch {
            if lane != nil { await directLane.endUse() }
            fields["error"] = String(describing: error).prefix(120).description
            journal.record("route", "dial-race-failed", fields)
            throw error
        }
    }

    /// The direct-lane session's admission failed (`DeviceIrxClient.dial`):
    /// the next dial skips the lane once.
    static func admissionFailed(instance: SurfaceDeviceInstanceID, journal: IrxJournal) async {
        await SupermuxComposition.routeSwitcher.directAdmissionFailed(instance)
        journal.record("route", "direct-admission-failed", ["device": String(instance.deviceID.prefix(8))])
    }
}

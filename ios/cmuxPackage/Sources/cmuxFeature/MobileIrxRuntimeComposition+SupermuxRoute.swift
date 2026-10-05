// SUPERMUX:begin phone-route-direct-race (whole file: the phone's per-Mac route, direct-lane dial race and upgrade prober — see SUPERMUX-TOUCHPOINTS.md)
import CMUXMobileCore
import CmuxIrxTransport
import Foundation
public import SupermuxMobileCore
public import SupermuxMobileKit

/// The phone's side of "always direct, via Tailscale or the LAN".
///
/// - **Route.** ``supermuxLinkPaths()`` reports every Mac session's
///   selected path for the Projects list (`SupermuxPhoneRouteModel`).
/// - **Addresses.** A Mac hands over its LAN and Tailscale addresses on its
///   authenticated link (`route.candidates`, fetched by the route model);
///   ``supermuxRecordRouteCandidates(_:macDeviceID:instanceTag:)`` keeps
///   them in a local file, never sent anywhere. A direct path a session
///   used is learned too.
/// - **Race.** An automatic dial with addresses on hand races the
///   direct-only endpoint (the Direct method's, relay disabled, same
///   identity) against the automatic dial, direct first
///   (``SupermuxDialRace``). A direct-lane session never authorizes NAT
///   traversal.
/// - **Prober.** While the app is active, a relayed session's direct lane
///   is probed on ``SupermuxRouteUpgradeSchedule``'s schedule; a probe that
///   works moves the session with one planned redial, whose race lands on
///   the direct lane.
/// - **Fallback.** A direct-lane session has no relay path to fall back on,
///   so one that goes silent, or stops answering after a network change, is
///   redialed at once; the race then picks the relay.
extension MobileIrxRuntimeComposition: SupermuxPhoneRouteRuntime {
    /// The time between prober passes.
    static let supermuxRouteTickInterval: Duration = .seconds(2)
    /// Silence on a direct-lane session that proves its path dead: two full
    /// keepalive cycles (5 s interval + 2 s deadline each).
    static let supermuxDirectSilenceWindow: Duration = .seconds(14)
    /// How long a network change settles before direct-lane sessions are
    /// checked, and each check's deadline.
    static let supermuxNetworkSettle: Duration = .seconds(1)
    static let supermuxLivenessDeadline: Duration = .milliseconds(1500)

    // MARK: - SupermuxPhoneRouteRuntime

    public func supermuxLinkPaths() async -> [SupermuxPhoneLinkPath] {
        var paths: [SupermuxPhoneLinkPath] = []
        for (peerHex, engine) in enginesByPeer {
            guard let record = supermuxMacRecord(endpointID: peerHex),
                  let session = await engine.currentSession(),
                  let sample = session.connection.supermuxSelectedPathSample() else { continue }
            paths.append(SupermuxPhoneLinkPath(
                macDeviceID: record.descriptor.identity.deviceID,
                instanceTag: record.descriptor.identity.buildTag,
                isRelay: sample.isRelay,
                remoteAddress: sample.remoteAddress,
                rttMs: sample.rttMs))
        }
        return paths
    }

    public func supermuxRecordRouteCandidates(
        _ answer: SupermuxRouteCandidatesDTO,
        macDeviceID: String,
        instanceTag: String?
    ) async {
        guard let record = supermuxMacRecord(macDeviceID: macDeviceID, instanceTag: instanceTag) else { return }
        let endpointID = record.descriptor.endpointID
        // Filed under the endpoint the directory names for this Mac; dials
        // to it are TLS-verified against that id, so a wrong address can only
        // waste a probe. An answer for another endpoint is dropped.
        if let claimed = answer.endpointID, claimed.lowercased() != endpointID.lowercased() { return }
        let key = Self.supermuxRoutePeerKey(record)
        let before = await supermuxRouteCandidates.dialAddresses(for: key)
        await supermuxRouteCandidates.recordFetched(answer.addresses, for: key)
        let after = await supermuxRouteCandidates.dialAddresses(for: key)
        journal.record("supermux-route", "candidates", [
            "peer": String(endpointID.prefix(12)), "count": String(after.count),
        ])
        if after != before { supermuxRouteSchedules[endpointID, default: .init()].candidatesChanged() }
        supermuxStartRouteLoopIfNeeded()
    }

    // MARK: - Dial race

    /// Dials a Mac for `dialOnce`. An automatic dial with the Mac's direct
    /// addresses on hand races the direct lane against `automatic`; every
    /// other dial is `automatic` alone.
    /// - Parameters:
    ///   - peerHex: The Mac's endpoint id.
    ///   - record: Its directory record.
    ///   - intent: The pairing's dial intent.
    ///   - privateAddresses: The user's Private Addresses for this Mac.
    ///   - automatic: The automatic endpoint's dial.
    /// - Returns: The connection, its lane, and whether the direct lane raced.
    func supermuxDial(
        peerHex: String,
        record: V2DeviceRecord,
        intent: DialIntent,
        privateAddresses: [String],
        automatic: @escaping @Sendable () async throws -> IrxConnection
    ) async throws -> (connection: IrxConnection, lane: SupermuxDialLane, raced: Bool) {
        guard case .automatic = intent, let lane = supermuxDirectLane() else {
            return (try await automatic(), .automatic, false)
        }
        let stored = await supermuxRouteCandidates.dialAddresses(for: Self.supermuxRoutePeerKey(record))
        var seen = Set<String>()
        let addresses = (stored + privateAddresses).filter { seen.insert($0).inserted }
            .prefix(SupermuxRouteCandidates.limit)
        guard !addresses.isEmpty,
              let address = try? lane.dialAddress(
                  peerEndpointIDHex: peerHex, relayURL: nil, directAddresses: Array(addresses)) else {
            return (try await automatic(), .automatic, false)
        }
        let started = ContinuousClock.now
        let result = try await SupermuxDialRace().run(
            direct: { try await lane.dial(address: address, credentials: []) },
            fallback: automatic,
            discard: { await $0.close(code: .explicitRedial, origin: .local) })
        journal.record("supermux-route", "dial-race", [
            "peer": String(peerHex.prefix(12)),
            "lane": result.lane.rawValue,
            "candidates": String(addresses.count),
            "elapsed_ms": String(Self.supermuxMilliseconds(started.duration(to: .now))),
            "path": result.value.selectedPathDescription(),
        ])
        return (result.value, result.lane, true)
    }

    /// Records the lane an admitted session used; arms the prober.
    func supermuxSessionAdmitted(
        peerHex: String,
        intent: DialIntent,
        dialed: (connection: IrxConnection, lane: SupermuxDialLane, raced: Bool)
    ) {
        guard case .automatic = intent else {
            supermuxLaneByPeer[peerHex] = nil
            return
        }
        supermuxLaneByPeer[peerHex] = dialed.lane
        supermuxRouteSchedules[peerHex, default: .init()].sessionAdmitted(
            direct: dialed.lane == .direct, directTried: dialed.raced, now: Date())
        supermuxStartRouteLoopIfNeeded()
    }

    /// The direct-only endpoint, built on first use with this installation's
    /// identity (the same construction as the Direct method's). Nil in
    /// relay-only mode and before the live identity is known.
    private func supermuxDirectLane() -> IrxEndpointSupervisor? {
        guard !forceRelayOnly, let identity else { return nil }
        if let directEndpointSupervisor { return directEndpointSupervisor }
        let lane = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
            identity: identity, pathMode: .directOnly, initialRemoteBiStreams: 0,
            initialRemoteUniStreams: 0), journal: journal, diagnosticLog: diagnosticLog)
        directEndpointSupervisor = lane
        return lane
    }

    // MARK: - Prober

    /// Starts the prober while the app is active. It ends on its own once
    /// the app leaves the foreground; the next foreground, network change or
    /// admitted session starts it again.
    func supermuxStartRouteLoopIfNeeded() {
        guard applicationActive, !forceRelayOnly, supermuxRouteLoop == nil else { return }
        supermuxRouteLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.supermuxRouteTick() else { return }
                try? await Task.sleep(for: Self.supermuxRouteTickInterval)
            }
        }
    }

    /// One pass over the automatic sessions; false ends the loop.
    private func supermuxRouteTick() async -> Bool {
        guard applicationActive else {
            supermuxRouteLoop = nil
            return false
        }
        for (peerHex, engine) in enginesByPeer {
            guard case .automatic = dialIntentByPeer[peerHex] ?? .automatic,
                  let record = supermuxMacRecord(endpointID: peerHex),
                  let session = await engine.currentSession(),
                  let sample = session.connection.supermuxSelectedPathSample() else { continue }
            let key = Self.supermuxRoutePeerKey(record)
            if sample.isRelay {
                await supermuxProbeIfDue(peerHex: peerHex, key: key, session: session)
            } else {
                // Every phone session is outgoing, so its direct path is one
                // the Mac accepts dials on. Only LAN and Tailscale are kept.
                if let scope = SupermuxSocketAddress(sample.remoteAddress)?.routeScope, scope != .internet {
                    await supermuxRouteCandidates.learn(sample.remoteAddress, for: key)
                }
                if supermuxLaneByPeer[peerHex] == .direct,
                   await session.connection.applicationSilenceEvidence(
                       since: .now - Self.supermuxDirectSilenceWindow) == .silent {
                    await supermuxRedial(peerHex: peerHex, engine: engine, replacing: session, reason: "fallback-silent")
                }
            }
        }
        return true
    }

    private func supermuxProbeIfDue(peerHex: String, key: SupermuxRoutePeerKey, session: IrxClientSession) async {
        guard supermuxRouteSchedules[peerHex, default: .init()].probeDue(
            onRelay: true, hasCandidates: true, now: Date()) else { return }
        let addresses = await supermuxRouteCandidates.dialAddresses(for: key)
        guard !addresses.isEmpty else { return }
        supermuxRouteSchedules[peerHex, default: .init()].probeStarted()
        Task { await self.supermuxProbe(peerHex: peerHex, session: session, addresses: addresses) }
    }

    /// One direct handshake that is never admitted; a success may move the
    /// session.
    private func supermuxProbe(peerHex: String, session: IrxClientSession, addresses: [String]) async {
        let started = ContinuousClock.now
        var worked = false
        if let lane = supermuxDirectLane(),
           let address = try? lane.dialAddress(peerEndpointIDHex: peerHex, relayURL: nil, directAddresses: addresses),
           let probe = try? await SupermuxDialRace().run(
               direct: { try await lane.dial(address: address, credentials: []) },
               fallback: nil,
               discard: { await $0.close(code: .explicitRedial, origin: .local) }) {
            await probe.value.close(code: .explicitRedial, origin: .local)
            worked = true
        }
        let move = supermuxRouteSchedules[peerHex, default: .init()].probeFinished(
            succeeded: worked, now: Date(), jitter: Double.random(in: -1...1))
        journal.record("supermux-route", "probe", [
            "peer": String(peerHex.prefix(12)), "ok": String(worked), "move": String(move),
            "elapsed_ms": String(Self.supermuxMilliseconds(started.duration(to: .now))),
        ])
        guard move, let engine = enginesByPeer[peerHex],
              session.connection.supermuxSelectedPathSample()?.isRelay == true else { return }
        await supermuxRedial(peerHex: peerHex, engine: engine, replacing: session, reason: "upgrade")
    }

    /// One planned redial of a Mac's session, if it is still the current one
    /// and the app is active. The new dial races the direct lane again.
    private func supermuxRedial(
        peerHex: String, engine: IrxPeerEngine, replacing session: IrxClientSession, reason: String
    ) async {
        guard applicationActive, await engine.currentSession()?.admit.session == session.admit.session else { return }
        journal.record("supermux-route", "redial", ["peer": String(peerHex.prefix(12)), "reason": reason])
        _ = try? await engine.ensureSession(explicit: true, trigger: "supermux-route-\(reason)")
    }

    // MARK: - Network change

    /// The phone's network changed (also on every foreground): probe relayed
    /// sessions at once, and check that direct-lane sessions still answer.
    func supermuxRouteNetworkChanged() {
        guard applicationActive, !forceRelayOnly else { return }
        for peerHex in supermuxRouteSchedules.keys {
            supermuxRouteSchedules[peerHex]?.networkChanged()
        }
        supermuxStartRouteLoopIfNeeded()
        for (peerHex, lane) in supermuxLaneByPeer where lane == .direct && !supermuxRouteChecks.contains(peerHex) {
            guard let engine = enginesByPeer[peerHex] else { continue }
            supermuxRouteChecks.insert(peerHex)
            Task { await self.supermuxCheckDirectSession(peerHex: peerHex, engine: engine) }
        }
    }

    /// Two missed liveness probes after the network settles redial the
    /// session. One miss proves nothing (a probe also fails while the
    /// connection is still resuming).
    private func supermuxCheckDirectSession(peerHex: String, engine: IrxPeerEngine) async {
        defer { supermuxRouteChecks.remove(peerHex) }
        try? await Task.sleep(for: Self.supermuxNetworkSettle)
        guard applicationActive, let session = await engine.currentSession() else { return }
        for _ in 0..<2 {
            if await session.connection.probeLiveness(deadline: Self.supermuxLivenessDeadline) { return }
            guard applicationActive else { return }
        }
        await supermuxRedial(peerHex: peerHex, engine: engine, replacing: session, reason: "fallback-network")
    }

    // MARK: - Directory

    private func supermuxMacRecord(endpointID: String) -> V2DeviceRecord? {
        cache?.directory?.devices.first {
            $0.descriptor.endpointID == endpointID && $0.descriptor.metadata.platform == .mac && !$0.revoked
        }
    }

    /// The Mac a pairing names: the exact build, else the only Mac build on
    /// that device.
    private func supermuxMacRecord(macDeviceID: String, instanceTag: String?) -> V2DeviceRecord? {
        let wanted = CmxMacAppInstanceIdentity(macDeviceID: macDeviceID, instanceTag: instanceTag)
        let macs = (cache?.directory?.devices ?? []).filter {
            $0.descriptor.metadata.platform == .mac && !$0.revoked
                && cmxCanonicalDeviceID($0.descriptor.identity.deviceID) == wanted.macDeviceID
        }
        let exact = macs.first {
            CmxMacAppInstanceIdentity(
                macDeviceID: $0.descriptor.identity.deviceID, instanceTag: $0.descriptor.identity.buildTag) == wanted
        }
        return exact ?? (macs.count == 1 ? macs[0] : nil)
    }

    private static func supermuxRoutePeerKey(_ record: V2DeviceRecord) -> SupermuxRoutePeerKey {
        SupermuxRoutePeerKey(
            deviceID: record.descriptor.identity.deviceID,
            tag: record.descriptor.identity.buildTag,
            endpointID: record.descriptor.endpointID)
    }

    private static func supermuxMilliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
// SUPERMUX:end phone-route-direct-race

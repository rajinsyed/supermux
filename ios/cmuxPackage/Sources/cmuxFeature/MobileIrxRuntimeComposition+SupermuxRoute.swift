// SUPERMUX:begin phone-route-direct-race (whole file: the phone's per-Mac route, direct-lane dial race and switch policy — see SUPERMUX-TOUCHPOINTS.md)
import CMUXMobileCore
import CmuxIrxTransport
import Foundation
public import SupermuxMobileCore
public import SupermuxMobileKit

/// The phone's side of "always direct, via Tailscale or the LAN", on the
/// switch policy the Mac runs for its links to other Macs
/// (``SupermuxPhoneRoutePolicies`` over SupermuxMobileCore's
/// `SupermuxRouteSwitchPolicy`).
///
/// - **Route.** ``supermuxLinkPaths()`` reports every Mac session's
///   selected path for the Projects list (`SupermuxPhoneRouteModel`).
/// - **Addresses.** A Mac hands over its LAN and Tailscale addresses on its
///   authenticated link (`route.candidates`, fetched by the route model);
///   ``supermuxRecordRouteCandidates(_:macDeviceID:instanceTag:)`` keeps
///   them in a local file, never sent anywhere. A direct path a session
///   used is learned too. Dials and probes use only the ones the phone can
///   reach from its interfaces now. Sign-out forgets them all, and a write
///   it overtook is undone (``supermuxRouteAddressEpoch``).
/// - **Race.** An automatic dial with reachable addresses races the
///   direct-only endpoint (the Direct method's, relay disabled, same
///   identity), one handshake per address, against the automatic dial with
///   the Mac's race (``supermuxRace(timing:direct:automatic:discard:)``):
///   direct wins whenever it connects within 1.5 s. Not while the policy
///   holds direct off after a flap, not once after a lane admission failed;
///   where direct keeps losing, the race stops holding a ready relay. A
///   direct-lane session never authorizes NAT traversal.
/// - **Prober.** While the app is active, a relayed session's direct lane
///   is probed when the policy says so; a probe that works moves the
///   session with one planned redial, whose race lands on the direct lane.
/// - **Fallback.** A direct-lane session has no relay path to fall back on,
///   so the policy has it checked; two unanswered checks redial it, and the
///   redial skips the lane while the flap's hold-off lasts.
/// - **Network.** A burst of path updates (and each foreground) settles for
///   a second, then the phone's interfaces decide: a real change clears the
///   hold-offs, anything else only probes relayed sessions soon.
extension MobileIrxRuntimeComposition: SupermuxPhoneRouteRuntime {
    /// The time between prober passes.
    static let supermuxRouteTickInterval: Duration = .seconds(2)
    /// How long the phone's network stays quiet before a change is judged.
    static let supermuxNetworkSettle: Duration = .seconds(1)
    /// How long a probe's handshake may take.
    static let supermuxProbeDeadline = SupermuxIrxDirectFirstDial.Timing.standard.directDeadline

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
                rttMs: sample.rttMs,
                sessionID: session.admit.session))
        }
        return paths
    }

    public func supermuxRecordRouteCandidates(
        _ answer: SupermuxRouteCandidatesDTO,
        macDeviceID: String,
        instanceTag: String?
    ) async -> SupermuxRouteCandidateFetchSchedule.Answer {
        let epoch = supermuxRouteAddressEpoch
        guard let record = supermuxMacRecord(macDeviceID: macDeviceID, instanceTag: instanceTag) else { return .failed }
        let endpointID = record.descriptor.endpointID
        // Filed under the endpoint the directory names for this Mac; dials
        // to it are TLS-verified against that id, so a wrong address can only
        // waste a probe. An answer for another endpoint is dropped.
        if let claimed = answer.endpointID, claimed.lowercased() != endpointID.lowercased() { return .failed }
        let key = Self.supermuxRoutePeerKey(record)
        let before = await supermuxRouteCandidates.dialAddresses(for: key)
        // An empty answer (a Mac before its first network report) keeps what the phone had.
        let stored = await supermuxRecordFetched(answer.addresses, for: key, epoch: epoch)
        guard epoch == supermuxRouteAddressEpoch else { return .failed }
        let after = await supermuxRouteCandidates.dialAddresses(for: key)
        journal.record("supermux-route", "candidates", [
            "peer": String(endpointID.prefix(12)), "count": String(after.count), "answer": stored ? "stored" : "empty",
        ])
        if after != before { supermuxRoutePolicies.candidatesChanged(for: endpointID, at: Date()) }
        supermuxStartRouteLoopIfNeeded()
        return stored ? .stored : .empty
    }

    public func supermuxForgetRouteCandidates(macDeviceID: String, instanceTag: String?) async {
        guard let record = supermuxMacRecord(macDeviceID: macDeviceID, instanceTag: instanceTag) else { return }
        await supermuxRouteCandidates.forget(Self.supermuxRoutePeerKey(record))
        journal.record("supermux-route", "candidates", [
            "peer": String(record.descriptor.endpointID.prefix(12)), "count": "0", "answer": "direct_off",
        ])
    }

    // MARK: - Dial race

    /// Dials a Mac for `dialOnce`. An automatic dial races the direct lane
    /// against `automatic` when the Mac's policy allows it and the phone can
    /// reach one of the Mac's direct addresses; every other dial is
    /// `automatic` alone. A network that changed since it was last judged is
    /// judged first: a foreground's dial comes before the settled judgement
    /// of its path updates and would otherwise run on the old network's
    /// hold-off, land on the relay and move seconds later.
    /// - Parameters:
    ///   - peerHex: The Mac's endpoint id.
    ///   - record: Its directory record.
    ///   - intent: The pairing's dial intent.
    ///   - privateAddresses: The user's Private Addresses for this Mac.
    ///   - automatic: The automatic endpoint's dial.
    /// - Returns: The connection and the lane it went out on.
    func supermuxDial(
        peerHex: String,
        record: V2DeviceRecord,
        intent: DialIntent,
        privateAddresses: [String],
        automatic: @escaping @Sendable () async throws -> IrxConnection
    ) async throws -> (connection: IrxConnection, lane: SupermuxDialLane) {
        guard case .automatic = intent, !forceRelayOnly else { return (try await automatic(), .automatic) }
        // The prober tries what this dial races, the Private Addresses included.
        supermuxPrivateAddressesByPeer[peerHex] = privateAddresses
        let interfaces = SupermuxLocalInterface.current()
        if supermuxRoutePolicies.judgeNetworkForDial(on: interfaces, at: Date()) {
            journal.record("supermux-route", "network-settled", ["changed": "true", "by": "dial"])
        }
        let plan = supermuxRoutePolicies.dialPlan(for: peerHex, at: Date())
        let addresses = plan.racesDirect
            ? await supermuxDirectAddresses(record: record, privateAddresses: privateAddresses, interfaces: interfaces) : []
        guard let lane = plan.racesDirect ? supermuxDirectLane() : nil,
              let direct = SupermuxIrxDirectFirstDial.laneLeg(lane: lane, peerEndpointIDHex: peerHex, addresses: addresses)
        else {
            let reason = !plan.racesDirect ? "hold-off" : addresses.isEmpty ? "no-addresses" : "no-lane"
            journal.record("supermux-route", "dial-direct-skipped", ["peer": String(peerHex.prefix(12)), "reason": reason])
            return (try await automatic(), .automatic)
        }
        let started = ContinuousClock.now
        let result = try await Self.supermuxRace(
            timing: plan.holdsRelay ? .standard : .noRelayHold,
            direct: direct,
            automatic: automatic,
            discard: { await $0.close(code: .explicitRedial, origin: .local) })
        supermuxRoutePolicies.raceFinished(for: peerHex, directWon: result.lane == .direct)
        var fields: [String: String] = [
            "peer": String(peerHex.prefix(12)),
            "lane": result.lane.rawValue,
            "candidates": String(addresses.count),
            "elapsed_ms": String(Self.supermuxMilliseconds(started.duration(to: .now))),
            "path": result.value.selectedPathDescription(),
        ]
        if !plan.holdsRelay { fields["holds_relay"] = "false" }
        journal.record("supermux-route", "dial-race", fields.merging(result.journalFields) { current, _ in current })
        return (result.value, result.lane)
    }

    /// The automatic dial as the race's relay leg: with no usable cached
    /// relay credential (none during an internet outage; expired after
    /// 30 min idle) it refreshes them first, inside the leg
    /// (``SupermuxIrxDirectFirstDial/relayLeg(credentials:dial:)``), so the
    /// direct lane races at once instead of waiting an HTTPS round trip, and
    /// a refresh that fails with the internet down fails only the relay leg.
    /// A leg cancelled while it refreshes (direct won) never dials.
    /// - Parameters:
    ///   - cached: The cached credentials.
    ///   - refresh: Mints fresh ones; nil where the dial may not refresh
    ///     (the Direct method, no control service).
    ///   - dial: The automatic endpoint's dial, with the credentials to use.
    /// - Returns: The leg; nothing runs until it is called.
    static func supermuxRelayLeg<Value: Sendable>(
        cached: [IrxRelayCredential],
        refresh: (@Sendable () async throws -> [IrxRelayCredential])?,
        dial: @escaping @Sendable ([IrxRelayCredential]) async throws -> Value
    ) -> @Sendable () async throws -> Value {
        SupermuxIrxDirectFirstDial.relayLeg(
            credentials: {
                guard let refresh, !cached.contains(where: { $0.isUsable(at: Date()) }) else { return cached }
                return try await refresh()
            },
            dial: dial)
    }

    /// How a dial with `intent` refreshes an expired relay credential:
    /// through the control service, re-checking `authority` after the
    /// round trip (as upstream did before its dial). Nil for the Direct
    /// method and without a control service.
    func supermuxCredentialRefresh(
        intent: DialIntent, authority: DialAuthority
    ) -> (@Sendable () async throws -> [IrxRelayCredential])? {
        guard case .automatic = intent, let control else { return nil }
        return {
            let fresh = try await control.refreshRelayCredentials().map {
                IrxRelayCredential(relayURL: $0.relayURL, token: $0.token,
                    expiresAt: Date(timeIntervalSince1970: Double($0.expiresAt)),
                    refreshAfter: Date(timeIntervalSince1970: Double($0.refreshAfter)))
            }
            try await self.assertDialAuthority(authority)
            return fresh
        }
    }

    /// The phone's dial race, which is the Mac's (``SupermuxIrxDirectFirstDial``).
    /// `direct` starts at once; `automatic` after 250 ms, or as soon as
    /// `direct` fails. Direct wins whenever it connects within 1.5 s, even
    /// when `automatic` is ready first (unless `timing` stops holding it):
    /// that connection is held, then closed. Exactly one connection comes out.
    /// - Returns: The winner, its lane, and what each leg did (journal fields).
    static func supermuxRace<Value: Sendable>(
        timing: SupermuxIrxDirectFirstDial.Timing = .standard,
        direct: @escaping @Sendable () async throws -> Value,
        automatic: @escaping @Sendable () async throws -> Value,
        discard: @escaping @Sendable (Value) async -> Void
    ) async throws -> (value: Value, lane: SupermuxDialLane, journalFields: [String: String]) {
        let outcome = try await SupermuxIrxDirectFirstDial.race(
            timing: timing, direct: direct, relay: automatic, discard: discard)
        return (outcome.value, outcome.leg == .direct ? .direct : .automatic, outcome.journalFields)
    }

    /// A dial's admission failed: a direct-lane one makes the next dial skip
    /// the lane once.
    func supermuxAdmissionFailed(peerHex: String, lane: SupermuxDialLane) {
        supermuxRoutePolicies.admissionFailed(for: peerHex, lane: lane)
        guard lane == .direct else { return }
        journal.record("supermux-route", "direct-admission-failed", ["peer": String(peerHex.prefix(12))])
    }

    /// A session was admitted: an automatic one is followed by the Mac's
    /// policy (and arms the prober); any other is not.
    func supermuxSessionAdmitted(peerHex: String, sessionID: String, intent: DialIntent, lane: SupermuxDialLane) {
        var followed: SupermuxDialLane?
        if case .automatic = intent { followed = lane }
        supermuxRoutePolicies.sessionAdmitted(
            for: peerHex, sessionID: sessionID, lane: followed, at: Date(), jitter: .random(in: 0...1))
        supermuxStartRouteLoopIfNeeded()
    }

    /// The direct-only endpoint, built on first use with this installation's
    /// identity (the same construction as the Direct method's): the live
    /// one, or at launch the warmed cached one, so a launch dial races too
    /// (sign-in for that account keeps the lane and its sessions). Nil in
    /// relay-only mode and before either identity is known.
    func supermuxDirectLane() -> IrxEndpointSupervisor? {
        guard !forceRelayOnly, let identity = identity ?? preparedCachedRuntime?.identity else { return nil }
        if let directEndpointSupervisor { return directEndpointSupervisor }
        let lane = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
            identity: identity, pathMode: .directOnly, initialRemoteBiStreams: 0,
            initialRemoteUniStreams: 0), journal: journal, diagnosticLog: diagnosticLog)
        directEndpointSupervisor = lane
        return lane
    }

    /// The Mac's direct addresses the phone can reach from `interfaces`
    /// (its handed-over and learned ones, then `privateAddresses`).
    private func supermuxDirectAddresses(
        record: V2DeviceRecord,
        privateAddresses: [String] = [],
        interfaces: [SupermuxLocalInterface] = SupermuxLocalInterface.current()
    ) async -> [String] {
        let stored = await supermuxRouteCandidates.dialAddresses(for: Self.supermuxRoutePeerKey(record))
        return SupermuxPhoneRoutePolicies.directAddresses(
            stored: stored, privateAddresses: privateAddresses, interfaces: interfaces)
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

    /// One pass over the followed Macs; false ends the loop.
    private func supermuxRouteTick() async -> Bool {
        guard applicationActive else {
            supermuxRouteLoop = nil
            return false
        }
        for peerHex in supermuxRoutePolicies.followedMacs {
            await supermuxRouteStep(peerHex: peerHex, now: Date())
        }
        return true
    }

    /// Feeds one Mac's live session to its policy and starts what it asks for.
    private func supermuxRouteStep(peerHex: String, now: Date) async {
        let epoch = supermuxRouteAddressEpoch
        let engine = enginesByPeer[peerHex]
        let session = await engine?.currentSession()
        let sample = session?.connection.supermuxSelectedPathSample()
        let record = supermuxMacRecord(endpointID: peerHex)
        if let sample, !sample.isRelay, let record {
            // Every phone session is outgoing, so its direct path is one the
            // Mac accepts dials on; the store keeps only servable addresses.
            await supermuxLearn(sample.remoteAddress, for: Self.supermuxRoutePeerKey(record), epoch: epoch)
        }
        var hasCandidates = false
        // The addresses cost a store hop and an interface read; only a due probe uses them.
        if sample?.isRelay == true, let record, supermuxRoutePolicies.probeDue(for: peerHex, at: now) {
            hasCandidates = await !supermuxDirectAddresses(
                record: record, privateAddresses: supermuxPrivateAddressesByPeer[peerHex] ?? []).isEmpty
        }
        let step = supermuxRoutePolicies.observe(
            peerHex,
            sessionID: session?.admit.session,
            sample: sample.map { SupermuxPhoneRoutePolicies.Sample(isRelay: $0.isRelay, hasRelayPath: $0.hasRelayPath) },
            hasCandidates: hasCandidates,
            at: now)
        guard let engine, let session else { return }
        switch step {
        case .none:
            break
        case .probe(let number):
            Task { await self.supermuxProbe(peerHex: peerHex, engine: engine, session: session, number: number) }
        case .checkLiveness(let number):
            Task { await self.supermuxCheck(peerHex: peerHex, engine: engine, session: session, number: number) }
        }
    }

    /// One direct handshake that is never admitted; a success may move the
    /// session.
    private func supermuxProbe(peerHex: String, engine: IrxPeerEngine, session: IrxClientSession, number: Int) async {
        let started = ContinuousClock.now
        var took: Duration?
        if let record = supermuxMacRecord(endpointID: peerHex), let lane = supermuxDirectLane() {
            took = await SupermuxIrxDirectFirstDial.probe(
                lane: lane, peerEndpointIDHex: peerHex,
                addresses: await supermuxDirectAddresses(
                    record: record, privateAddresses: supermuxPrivateAddressesByPeer[peerHex] ?? []),
                deadline: Self.supermuxProbeDeadline)
        }
        let action = supermuxRoutePolicies.probeFinished(
            for: peerHex, session: number, succeeded: took != nil, at: Date(), jitter: .random(in: 0...1))
        journal.record("supermux-route", "probe", [
            "peer": String(peerHex.prefix(12)), "ok": String(took != nil), "move": String(action == .upgrade),
            "failures": String(supermuxRoutePolicies.policy(for: peerHex)?.probeFailures ?? 0),
            "elapsed_ms": String(Self.supermuxMilliseconds(started.duration(to: .now))),
        ])
        guard action == .upgrade, await supermuxMayRedial(engine, replacing: session) else { return }
        // Only a move that happened spaces the next one and counts as a
        // flap should it land on the relay.
        supermuxRoutePolicies.upgradeStarted(for: peerHex, at: Date())
        await supermuxRedial(peerHex: peerHex, engine: engine, reason: "upgrade")
    }

    /// Whether a direct session still answers: its peer's bytes arrived
    /// lately, or it answers a ping (at once within a few seconds of a real
    /// network change). Two misses fall back to the relay.
    private func supermuxCheck(peerHex: String, engine: IrxPeerEngine, session: IrxClientSession, number: Int) async {
        let urgent = supermuxRoutePolicies.isUrgent(at: Date())
        // A suspended app's sessions prove nothing either way.
        let answered = applicationActive
            ? await SupermuxIrxDirectFirstDial.answers(
                session.connection, quietFor: urgent ? .zero : SupermuxIrxDirectFirstDial.quietBeforeProbe)
            : true
        let action = supermuxRoutePolicies.livenessChecked(for: peerHex, session: number, answered: answered, at: Date())
        guard !answered else { return }
        journal.record("supermux-route", "liveness-miss", ["peer": String(peerHex.prefix(12)), "urgent": String(urgent)])
        guard action == .fallBack, await supermuxMayRedial(engine, replacing: session) else { return }
        let policy = supermuxRoutePolicies.policy(for: peerHex)
        journal.record("supermux-route", "fallback", [
            "peer": String(peerHex.prefix(12)),
            "flaps": String(policy?.flaps ?? 0),
            "hold_off_s": policy?.holdOffUntil.map { String(Int($0.timeIntervalSinceNow.rounded())) } ?? "0",
        ])
        await supermuxRedial(peerHex: peerHex, engine: engine, reason: "fallback")
    }

    /// Whether a planned redial may replace `session`: the app is active and
    /// it is still the engine's live session.
    private func supermuxMayRedial(_ engine: IrxPeerEngine, replacing session: IrxClientSession) async -> Bool {
        guard applicationActive else { return false }
        return await engine.currentSession()?.admit.session == session.admit.session
    }

    /// One planned redial of a Mac's session; the new dial asks the policy
    /// whether to race the direct lane again.
    private func supermuxRedial(peerHex: String, engine: IrxPeerEngine, reason: String) async {
        journal.record("supermux-route", "redial", ["peer": String(peerHex.prefix(12)), "reason": reason])
        _ = try? await engine.ensureSession(explicit: true, trigger: "supermux-route-\(reason)")
    }

    // MARK: - Network change

    /// The phone's network may have changed (every path update, and every
    /// foreground): judged once the updates stop for
    /// ``supermuxNetworkSettle``.
    func supermuxRouteNetworkChanged() {
        guard !forceRelayOnly else { return }
        supermuxNetworkDebounce.poke { [weak self] in await self?.supermuxNetworkSettled() }
        supermuxStartRouteLoopIfNeeded()
    }

    /// The network settled: a real change (other interfaces or addresses)
    /// clears every Mac's hold-off and has direct sessions checked at once;
    /// otherwise relayed sessions only probe soon.
    func supermuxNetworkSettled() {
        let changed = supermuxRoutePolicies.networkSettled(on: SupermuxLocalInterface.current(), at: Date())
        journal.record("supermux-route", "network-settled", ["changed": String(changed)])
        supermuxStartRouteLoopIfNeeded()
    }

    // MARK: - State

    /// The file each Mac's direct addresses are kept in:
    /// `<Iroh state>/supermux-route/candidates.json`. Its directory is the
    /// app's alone (0700), excluded from backups and, on the device,
    /// protected until first unlock (files made in it inherit both), like the
    /// Iroh local-path store's. The first builds kept the file beside the
    /// Iroh state with neither: its addresses move in once (so the first
    /// dial to each Mac after the update still races direct), never over a
    /// newer file, and the old copy is removed.
    nonisolated static func supermuxRouteCandidatesFile(stateDirectory: URL) -> URL {
        let files = FileManager()
        let directory = stateDirectory.appendingPathComponent("supermux-route", isDirectory: true)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #if os(iOS)
        try? files.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)
        let file = directory.appendingPathComponent("candidates.json")
        let legacy = stateDirectory.appendingPathComponent("supermux-route-candidates.json")
        if files.fileExists(atPath: legacy.path) {
            if !files.fileExists(atPath: file.path), let data = try? Data(contentsOf: legacy) {
                // Written anew inside the directory, so the copy takes its protection.
                try? data.write(to: file, options: [.atomic])
                try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            try? files.removeItem(at: legacy)
        }
        return file
    }

    /// The runtime was detached without keeping its sessions (a sign-out, an
    /// account or team change): every Mac's route state goes with it, and on
    /// sign-out the cached direct addresses too.
    func supermuxResetRouteState(forgetAddresses: Bool) async {
        supermuxRouteLoop?.cancel()
        supermuxRouteLoop = nil
        supermuxNetworkDebounce.cancel()
        supermuxRoutePolicies.reset()
        supermuxPrivateAddressesByPeer = [:]
        guard forgetAddresses else { return }
        // Before the first await: a write still out sees it and undoes itself.
        supermuxRouteAddressEpoch &+= 1
        for peer in await supermuxRouteCandidates.peers() {
            await supermuxRouteCandidates.forget(peer.key)
        }
    }

    /// Records a Mac's handed-over addresses, decided in address `epoch`.
    /// A sign-out that came first skips the write; one that came while it
    /// was out undoes it (``supermuxAddressWriteStands(for:epoch:)``).
    /// - Returns: Whether the addresses are stored.
    @discardableResult
    func supermuxRecordFetched(_ addresses: [String], for key: SupermuxRoutePeerKey, epoch: UInt64) async -> Bool {
        guard epoch == supermuxRouteAddressEpoch else { return false }
        let stored = await supermuxRouteCandidates.recordFetched(addresses, for: key)
        return await supermuxAddressWriteStands(for: key, epoch: epoch) && stored
    }

    /// Records a direct path a session used, decided in address `epoch`,
    /// under the same rule as ``supermuxRecordFetched(_:for:epoch:)``.
    func supermuxLearn(_ address: String, for key: SupermuxRoutePeerKey, epoch: UInt64) async {
        guard epoch == supermuxRouteAddressEpoch else { return }
        await supermuxRouteCandidates.learn(address, for: key)
        await supermuxAddressWriteStands(for: key, epoch: epoch)
    }

    /// Whether a write for `key` decided in address `epoch` stands: one a
    /// sign-out overtook (it forgot every address while the write was out)
    /// is undone, so the signed-out account's addresses never come back. A
    /// sign-in right behind that sign-out may lose this Mac's first
    /// addresses too; its next fetch or learned path brings them back.
    @discardableResult
    private func supermuxAddressWriteStands(for key: SupermuxRoutePeerKey, epoch: UInt64) async -> Bool {
        guard epoch != supermuxRouteAddressEpoch else { return true }
        await supermuxRouteCandidates.forget(key)
        return false
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

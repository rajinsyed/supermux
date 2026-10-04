import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

extension MobileIrxRuntimeComposition {
    func peerTarget(for request: CmxByteTransportRequest) throws -> String {
        guard request.route.kind == .iroh, case let .peer(identity, _) = request.route.endpoint else {
            throw CompositionError.unsupportedRoute
        }
        if let deviceID = request.expectedPeerDeviceID { expectedDeviceIDByPeer[identity.endpointID] = deviceID }
        dialIntentByPeer[identity.endpointID] = request.irohDirectOnlyDialCandidates.map { .direct($0) } ?? .automatic
        return identity.endpointID
    }

    func engine(forPeer peerHex: String) -> IrxPeerEngine {
        if let engine = enginesByPeer[peerHex] { return engine }
        let engine = IrxPeerEngine(journal: journal, label: String(peerHex.prefix(12)),
            applicationActive: applicationActive) { [weak self] in
            guard let self else { throw CompositionError.notSignedIn }
            return try await self.dialOnce(peerHex: peerHex)
        }
        enginesByPeer[peerHex] = engine
        return engine
    }

    func ensureSession(forPeer peerHex: String, trigger: String) async throws -> IrxClientSession {
        // SUPERMUX:begin mobile-irx-cached-dial-authority
        let authority = try await waitForRuntimeReadiness(for: peerHex)
        try await assertDialAuthority(authority)
        let desired = dialIntentByPeer[peerHex] ?? .automatic
        let replace = activeDialIntentByPeer[peerHex].map { $0 != desired } ?? false
        let session = try await engine(forPeer: peerHex).ensureSession(explicit: replace, trigger: trigger)
        try await assertDialAuthority(authority)
        // SUPERMUX:end mobile-irx-cached-dial-authority
        return session
    }

    // SUPERMUX:begin mobile-irx-cached-dial-authority
    private func waitForRuntimeReadiness(
        for peerHex: String
    ) async throws -> DialAuthority {
        if let ready = await dialAuthority(for: peerHex) {
            return ready
        }

        let becameReady = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                for await _ in await self.changes() {
                    guard !Task.isCancelled else { return false }
                    if await self.dialAuthority(for: peerHex) != nil {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard becameReady, let ready = await dialAuthority(for: peerHex) else {
            throw CompositionError.notSignedIn
        }
        return ready
    }

    /// Who a dial runs for: the live scope, or, while sign-in restores the
    /// session at launch, the account and team the runtime warmed for.
    enum DialAuthority: Sendable {
        case live(AuthenticatedTeamScope, epoch: UInt64)
        /// The warmed supervisor ties the dial to the runtime it was granted
        /// under: a sign-out and sign-in for the same pair replaces it.
        case cached(V2CachedDialAuthority, supervisor: IrxEndpointSupervisor)
    }

    /// The authority a dial to this peer may run under now, if any.
    func dialAuthority(for peerHex: String) async -> DialAuthority? {
        if let ready = runtimeReadinessState(for: peerHex) {
            return .live(ready.scope, epoch: ready.epoch)
        }
        guard activeScope == nil, case .automatic = dialIntentByPeer[peerHex] ?? .automatic,
              let prepared = preparedCachedRuntime?.tuple else { return nil }
        let signedIn = await auth?.cachedTeamIdentity
        guard activeScope == nil, preparedCachedRuntime?.tuple == prepared,
              let cached = V2CachedDialAuthority(
                  prepared: prepared,
                  signedIn: signedIn.map { V2AccountTeam(accountID: $0.accountID, teamID: $0.teamID) },
                  cache: cache,
                  now: Date()
              ),
              let supervisor = preparedCachedRuntime?.supervisor,
              cachedDialDirectory(cached) != nil else { return nil }
        return .cached(cached, supervisor: supervisor)
    }

    /// Throws once the account or team a dial runs for is no longer signed in.
    func assertDialAuthority(_ authority: DialAuthority) async throws {
        switch authority {
        case let .live(scope, epoch):
            try await assertScope(scope, epoch: epoch)
        case let .cached(cached, supervisor):
            let scope = activeScope
            var liveScopeIsCurrent = false
            if let scope, let auth { liveScopeIsCurrent = await auth.isAuthenticatedTeamScopeCurrent(scope) }
            let signedIn = await auth?.cachedTeamIdentity
            guard activeScope == scope,
                  endpointSupervisor === supervisor || preparedCachedRuntime?.supervisor === supervisor,
                  cached.isCurrent(
                liveScope: scope.map { V2AccountTeam(accountID: $0.session.accountID, teamID: $0.teamID) },
                liveScopeIsCurrent: liveScopeIsCurrent,
                prepared: preparedCachedRuntime?.tuple,
                signedIn: signedIn.map { V2AccountTeam(accountID: $0.accountID, teamID: $0.teamID) }
            ) else { throw CompositionError.scopeChanged }
        }
    }

    /// The warmed directory a cached dial reads, while it still grants access.
    private func cachedDialDirectory(_ cached: V2CachedDialAuthority) -> V2Directory? {
        guard let directory = cache?.directory, cache?.authorityRevoked == false,
              directory.teamID == cached.tuple.teamID,
              directory.permissionExpiresAt > Int(Date().timeIntervalSince1970) else { return nil }
        return directory
    }
    // SUPERMUX:end mobile-irx-cached-dial-authority

    private func runtimeReadinessState(
        for peerHex: String
    ) -> (scope: AuthenticatedTeamScope, epoch: UInt64)? {
        guard let scope = activeScope, let cache, !cache.authorityRevoked else {
            return nil
        }
        switch dialIntentByPeer[peerHex] ?? .automatic {
        case .automatic:
            // The supervisor binds or repairs its endpoint during dial.
            guard endpointSupervisor != nil else { return nil }
        case .direct:
            guard identity != nil else { return nil }
        }
        return (scope, epoch)
    }

    // SUPERMUX:begin mobile-irx-cached-dial-authority (dialOnce runs under a DialAuthority: live scope or the warmed cached identity)
    func dialOnce(peerHex: String) async throws -> IrxClientSession {
        // Waits, like upstream's live discovery, while sign-in hands the warmed
        // runtime over to the live scope.
        let authority = try await waitForRuntimeReadiness(for: peerHex)
        let discovered: V2Directory?
        switch authority {
        case .live: discovered = await freshLiveDiscovery()
        case let .cached(cached, _): discovered = cachedDialDirectory(cached)
        }
        guard let directory = discovered else { throw CompositionError.peerNotDiscovered }
        try await assertDialAuthority(authority)
        guard let record = directory.devices.first(where: { $0.descriptor.endpointID == peerHex }),
              !record.revoked, record.descriptor.metadata.pairingEnabled,
              record.descriptor.metadata.platform == .mac else { throw IrxAdmissionDenied(code: .revoked) }
        if let expected = expectedDeviceIDByPeer[peerHex],
           cmxCanonicalDeviceID(expected) != cmxCanonicalDeviceID(record.descriptor.identity.deviceID) {
            throw CompositionError.peerNotDiscovered
        }
        let intent = dialIntentByPeer[peerHex] ?? .automatic
        let selectedSupervisor: IrxEndpointSupervisor?
        switch intent {
        case .automatic: selectedSupervisor = endpointSupervisor ?? preparedCachedRuntime?.supervisor
        case .direct:
            guard !forceRelayOnly, let identity else { throw CompositionError.directDialUnavailable }
            if directEndpointSupervisor == nil {
                // Both local endpoints represent this same enrolled installation.
                // A separate transport is needed because relay policy is endpoint-wide.
                directEndpointSupervisor = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
                    identity: identity, pathMode: .directOnly, initialRemoteBiStreams: 0,
                    initialRemoteUniStreams: 0), journal: journal, diagnosticLog: diagnosticLog)
            }
            selectedSupervisor = directEndpointSupervisor
        }
        guard let supervisor = selectedSupervisor, let cache, !cache.authorityRevoked else {
            throw CompositionError.notSignedIn
        }
        var credentials = Self.credentials(cache)
        if case .automatic = intent, !credentials.contains(where: { $0.isUsable(at: Date()) }), let control {
            credentials = try await control.refreshRelayCredentials().map {
                IrxRelayCredential(relayURL: $0.relayURL, token: $0.token,
                    expiresAt: Date(timeIntervalSince1970: Double($0.expiresAt)),
                    refreshAfter: Date(timeIntervalSince1970: Double($0.refreshAfter)))
            }
        }
        try await assertDialAuthority(authority)
        let relay: String?
        var direct: [String]
        switch intent {
        case .automatic:
            // The Mac's current home relay is the useful route hint. The
            // team fleet remains a safe fallback while a freshly registered
            // Mac publishes that hint.
            relay = record.descriptor.metadata.relayURLs.first ?? directory.relayURLs.first
            direct = []
            if !forceRelayOnly {
                let paths = (try? await localPaths.load(identity: cache.identity)) ?? []
                for path in paths where path.isEnabled
                    && path.macDeviceID == record.descriptor.identity.deviceID
                    && path.instanceTag == record.descriptor.identity.buildTag {
                    direct.append(contentsOf: path.addresses.compactMap { try? CmxIrohLocalSocketAddress($0).value })
                }
            }
        case let .direct(candidates):
            guard !forceRelayOnly else { throw CompositionError.directDialUnavailable }
            relay = nil
            direct = candidates.prefix(16).compactMap { candidate in
                guard let port = candidate.port, port != 0,
                      let address = try? CmxIrohCustomPrivateAddress(candidate.address) else { return nil }
                return address.socketAddress(port: port)
            }
            guard !direct.isEmpty else { throw CompositionError.directDialUnavailable }
        }
        try await assertDialAuthority(authority)
        let address = try supervisor.dialAddress(peerEndpointIDHex: peerHex, relayURL: relay, directAddresses: direct)
        let connection = try await supervisor.dial(address: address, credentials: credentials)
        do {
            try await assertDialAuthority(authority)
            var authorizesDirectPaths = false
            if !forceRelayOnly, case .automatic = intent { authorizesDirectPaths = true }
            let (admit, control) = try await IrxAdmission().performClient(
                connection: connection, journal: journal,
                authorizesDirectPaths: authorizesDirectPaths,
                // Scope recheck before NAT traversal authorizes, so a dial
                // superseded during admission never discloses candidates.
                preAuthorization: { [weak self] in
                    guard let self else { throw CompositionError.directDialUnavailable }
                    try await self.assertDialAuthority(authority)
                })
            try await assertDialAuthority(authority)
            // One shared events lane plus up to 16 per-terminal output lanes
            // (IrxSurfaceEventLanes), with headroom for streams the Mac is
            // replacing. An older Mac opens only the shared lane.
            await connection.raiseRemoteStreamCredit(bi: 0, uni: 40)
            try await assertDialAuthority(authority)
            activeDialIntentByPeer[peerHex] = intent
            admittedSessionCount += 1
            journal.record("v2-peer", "admitted", ["session": admit.session, "count": String(admittedSessionCount),
                "launchMs": String(Int(Date().timeIntervalSince(launchTime) * 1000))])
            return IrxClientSession(connection: connection, admit: admit, control: control, establishedAt: Date())
        } catch {
            await connection.close(code: .userRequested, origin: .local)
            throw error
        }
    }
    // SUPERMUX:end mobile-irx-cached-dial-authority
}

public import Foundation
public import SupermuxMobileKit

/// The per-Mac session lifecycle of ``SupermuxProjectsSectionModel``: which
/// Macs have sessions, running each one, and ending them when a Mac goes
/// away. Each Mac's session pauses on a navigation push and resumes on pop
/// independently (m6-f3; see ``SupermuxMacProjectsSession``).
extension SupermuxProjectsSectionModel {
    /// Runs one Mac's session and follows its live event streams until the
    /// caller (the driver's `.task(id:)`) is cancelled — which only PAUSES it.
    /// A re-run with the SAME `connectionID` resumes the retained stores; a
    /// different one replaces them.
    /// - Parameters:
    ///   - mac: The Mac this session serves.
    ///   - client: The Mac's RPC seam. Ignored on resume.
    ///   - hostCapabilities: The Mac's raw advertised capabilities.
    ///   - connectionID: The connection identity; `nil` always replaces.
    public func runSession(
        mac: SupermuxMacInfo,
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>,
        connectionID: AnyHashable? = nil
    ) async {
        let session = sessions[mac.pairingID] ?? makeSession(for: mac)
        if session.mac != mac {
            session.mac = mac
        }
        await session.run(client: client, hostCapabilities: hostCapabilities, connectionID: connectionID)
    }

    /// Runs every given Mac's session concurrently until cancelled (which
    /// pauses them all). One main-actor task per Mac, cancelled together with
    /// the caller — the driver's structured `.task`.
    /// - Parameter seams: The Macs whose sessions should run.
    public func runSessions(_ seams: [SupermuxMacSeam]) async {
        let runs = seams.map { seam in
            Task { [weak self] in
                await self?.runSession(
                    mac: SupermuxMacInfo(seam: seam),
                    client: SupermuxMacClient(client: seam.client),
                    hostCapabilities: seam.hostCapabilities,
                    connectionID: SupermuxProjectsConnectionKey(seam: seam)
                )
            }
        }
        await withTaskCancellationHandler {
            for run in runs {
                await run.value
            }
        } onCancel: {
            for run in runs {
                run.cancel()
            }
        }
    }

    /// Runs the single, unidentified Mac's session (the pre-multi-Mac API).
    /// - Parameters:
    ///   - client: The Mac RPC seam for this connection.
    ///   - hostCapabilities: The host's raw advertised capability strings.
    ///   - connectionID: The connection identity; `nil` always replaces.
    public func runSession(
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>,
        connectionID: AnyHashable? = nil
    ) async {
        await runSession(mac: .legacy, client: client, hostCapabilities: hostCapabilities, connectionID: connectionID)
    }

    /// Records the connected Macs (display order, header facts) and ends the
    /// session of every Mac no longer among them.
    /// - Parameter macs: Every connected Mac, foreground first.
    public func updateMacs(_ macs: [SupermuxMacInfo]) {
        let order = macs.map(\.pairingID)
        if macOrder != order {
            macOrder = order
        }
        for mac in macs {
            if let session = sessions[mac.pairingID], session.mac != mac {
                session.mac = mac
            }
        }
        let live = Set(order)
        for pairingID in sessions.keys where !live.contains(pairingID) {
            endSession(pairingID: pairingID)
        }
    }

    /// Ends one Mac's session (its connection went away). Expansion state
    /// persists; a pushed detail keeps its last-known row.
    /// - Parameter pairingID: The Mac's pairing id.
    public func endSession(pairingID: String) {
        guard let session = sessions.removeValue(forKey: pairingID) else { return }
        session.end()
        resetTransientState(forPairingID: pairingID)
        if sessions.isEmpty {
            collapsedOverride = nil
        }
    }

    /// Ends every Mac's session.
    public func endSession() {
        for pairingID in Array(sessions.keys) {
            endSession(pairingID: pairingID)
        }
        collapsedOverride = nil
    }

    private func makeSession(for mac: SupermuxMacInfo) -> SupermuxMacProjectsSession {
        let pairingID = mac.pairingID
        let session = SupermuxMacProjectsSession(mac: mac, iconCache: iconCache, counter: counter)
        session.expandedProjectIDs = { [weak self] in
            self?.expandedProjectIDs(onPairingID: pairingID) ?? []
        }
        session.onReplaced = { [weak self] in
            self?.sessionReplaced(pairingID: pairingID)
        }
        sessions[pairingID] = session
        return session
    }

    /// A Mac's connection was replaced: UI state raised against the old
    /// connection must not survive into the new one.
    private func sessionReplaced(pairingID: String) {
        if primarySession?.pairingID == pairingID {
            collapsedOverride = nil
        }
        resetTransientState(forPairingID: pairingID)
    }

    /// Drops the confirmations, sheets and parked navigation that belong to
    /// one Mac's (dead) connection. Other Macs' state is untouched.
    func resetTransientState(forPairingID pairingID: String) {
        // A confirmation against the old connection could delete a DIFFERENT
        // checkout that now sits at the same path.
        if let pending = pendingWorktreeRemoval,
           SupermuxProjectKey(rawValue: pending.projectID).pairingID == pairingID {
            pendingWorktreeRemoval = nil
        }
        // The create flow's stores belong to the dead connection.
        if newWorktreePresentation?.pairingIDs.contains(pairingID) == true
            || preparingNewWorktreeProjectID.map({ SupermuxProjectKey(rawValue: $0).pairingID }) == pairingID
            || (newWorktreeErrorMessage != nil && newWorktreeErrorPairingID == pairingID) {
            resetNewWorktreeFlow()
        }
        if let target = navigator.pendingTarget,
           SupermuxMacSeam.pairingID(macDeviceID: target.macDeviceID, instanceTag: target.instanceTag) == pairingID {
            navigator.cancelPending()
        }
    }
}

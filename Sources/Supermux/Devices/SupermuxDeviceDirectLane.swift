import CmuxIrxTransport
import Foundation

/// This Mac's direct lane: a second iroh endpoint with the Mac's own
/// identity and every relay disabled, used only for outgoing links to the
/// user's other Macs (the dial's direct leg, ``SupermuxDeviceDirectDial``) and
/// for route probes (``SupermuxDeviceRouteSwitcher``). The phone's "Direct"
/// connection method builds the same kind of endpoint.
///
/// Why a second endpoint: on the shared host endpoint iroh keeps one state
/// per peer for both directions, so a dial there starts on whatever path that
/// state already selected (usually the relay, under the other Mac's inbound
/// session), and a direct path that once stalled is blocked for 5–300 s. The
/// lane never authorizes NAT traversal, so neither happens; and it serves no
/// phone and no inbound link, so it can be closed and rebound at any time
/// without dropping them. Its address is never advertised or learned.
actor SupermuxDeviceDirectLane {
    private let journal: IrxJournal
    private var supervisor: IrxEndpointSupervisor?
    private var endpointID: String?
    /// Admitted sessions on the lane; closing it while one is live would drop that link.
    private var sessions: [WeakConnection] = []

    private struct WeakConnection {
        weak var connection: IrxConnection?
    }

    init(journal: IrxJournal) {
        self.journal = journal
    }

    /// The lane for the identity `main` uses: made on first use, replaced
    /// when the identity changes (another account). It binds on its first dial.
    func supervisor(matching main: IrxEndpointSupervisor) async -> IrxEndpointSupervisor {
        let identity = await main.identity()
        if let supervisor, endpointID == identity.endpointIDHex { return supervisor }
        let previous = supervisor
        let lane = IrxEndpointSupervisor(
            configuration: IrxEndpointConfiguration(
                identity: identity, pathMode: .directOnly,
                initialRemoteBiStreams: 0, initialRemoteUniStreams: 0),
            journal: journal)
        supervisor = lane
        endpointID = identity.endpointIDHex
        sessions = []
        journal.record("route", "lane-created", ["endpoint_id": String(identity.endpointIDHex.prefix(12))])
        await previous?.deactivate()
        return lane
    }

    /// The lane as last made; nil before the first dial that could use it.
    func current() -> IrxEndpointSupervisor? {
        supervisor
    }

    /// A session the dial put on the lane.
    func adopt(_ connection: IrxConnection) {
        sessions.removeAll { $0.connection == nil }
        sessions.append(WeakConnection(connection: connection))
    }

    /// Closes the lane's endpoint when no session uses it, so the next dial or
    /// probe binds a fresh socket (wake, a network change). Returns whether it did.
    @discardableResult
    func rebuildIfIdle(reason: String) async -> Bool {
        guard let supervisor else { return false }
        for weak in sessions {
            if let connection = weak.connection, await !connection.isConnectionClosed() { return false }
        }
        sessions = []
        await supervisor.close()
        journal.record("route", "lane-rebuilt", ["reason": reason])
        return true
    }
}

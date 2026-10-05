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
///
/// It is rebound (``rebuildIfIdle(reason:)``, on wake and network changes)
/// only while nothing uses it: no adopted session is live and no dial or
/// probe holds it (``beginUse(matching:)`` … ``endUse()``). Sign-out takes
/// it down with the old identity (``deactivate()``).
actor SupermuxDeviceDirectLane {
    private let journal: IrxJournal
    private var supervisor: IrxEndpointSupervisor?
    private var endpointID: String?
    /// Admitted sessions on the lane; closing it while one is live would drop that link.
    private var sessions: [WeakConnection] = []
    /// Dials and probes using the lane now.
    private var inFlight = 0

    private struct WeakConnection {
        weak var connection: IrxConnection?
    }

    init(journal: IrxJournal) {
        self.journal = journal
    }

    /// The lane for the identity `main` uses, held for one dial or probe until
    /// ``endUse()``: made on first use, replaced when the identity changes
    /// (another account). It binds on its first dial.
    func beginUse(matching main: IrxEndpointSupervisor) async -> IrxEndpointSupervisor {
        inFlight += 1
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

    /// A dial or probe is done with the lane.
    func endUse() {
        inFlight = max(0, inFlight - 1)
    }

    /// A session the dial put on the lane.
    func adopt(_ connection: IrxConnection) {
        sessions.removeAll { $0.connection == nil }
        sessions.append(WeakConnection(connection: connection))
    }

    /// Closes the lane's endpoint when nothing uses it, so the next dial or
    /// probe binds a fresh socket (wake, a network change). Returns whether it did.
    @discardableResult
    func rebuildIfIdle(reason: String) async -> Bool {
        guard let supervisor, inFlight == 0 else { return false }
        for weak in sessions {
            if let connection = weak.connection, await !connection.isConnectionClosed() { return false }
        }
        // A dial may have started while the sessions were looked at.
        guard inFlight == 0, self.supervisor === supervisor else { return false }
        sessions = []
        await supervisor.close()
        journal.record("route", "lane-rebuilt", ["reason": reason])
        return true
    }

    /// The account changed or signed out: the lane and its identity go now.
    func deactivate() async {
        guard let previous = supervisor else { return }
        supervisor = nil
        endpointID = nil
        sessions = []
        await previous.deactivate()
        journal.record("route", "lane-deactivated")
    }
}

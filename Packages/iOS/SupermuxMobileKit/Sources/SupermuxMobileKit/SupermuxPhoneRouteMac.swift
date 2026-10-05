/// One Mac the route model follows: its pairing, the identity of its current
/// connection, and how to ask it for its direct addresses.
public struct SupermuxPhoneRouteMac: Sendable {
    /// What restarts the model's task: the pairing and its connection.
    public struct Identity: Hashable, Sendable {
        /// The pairing id.
        public let pairingID: String
        /// The connection's identity; a new connection asks for addresses again.
        public let connectionID: ObjectIdentifier?
        /// Whether the Mac serves its direct addresses.
        public let servesCandidates: Bool
    }

    /// The pairing id (``SupermuxMacSeam/pairingID``).
    public let pairingID: String
    /// The Mac's device id, if known.
    public let macDeviceID: String?
    /// The pairing's build tag, if any.
    public let instanceTag: String?
    /// The current connection's identity.
    public let connectionID: ObjectIdentifier?
    /// Asks the Mac for its direct addresses; nil when it does not serve them.
    public let candidates: (any SupermuxRouteCandidatesCalling)?

    /// Creates a Mac.
    /// - Parameters:
    ///   - pairingID: The pairing id.
    ///   - macDeviceID: The Mac's device id.
    ///   - instanceTag: The pairing's build tag.
    ///   - connectionID: The current connection's identity.
    ///   - candidates: Asks the Mac for its direct addresses.
    public init(
        pairingID: String,
        macDeviceID: String?,
        instanceTag: String?,
        connectionID: ObjectIdentifier?,
        candidates: (any SupermuxRouteCandidatesCalling)?
    ) {
        self.pairingID = pairingID
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.connectionID = connectionID
        self.candidates = candidates
    }

    /// A connected seam's Mac; its addresses are asked for only when it
    /// advertises `supermux.route_candidates.v1`.
    /// - Parameter seam: The shell's seam for the Mac.
    public init(seam: SupermuxMacSeam) {
        let serves = seam.status == .connected
            && SupermuxMobileCapabilities(hostCapabilities: seam.hostCapabilities).supportsRouteCandidates
        self.init(
            pairingID: seam.pairingID,
            macDeviceID: seam.macDeviceID,
            instanceTag: seam.instanceTag,
            connectionID: ObjectIdentifier(seam.client),
            candidates: serves ? SupermuxRouteCandidatesClient(client: seam.client) : nil
        )
    }

    /// The model task's identity for this Mac.
    public var identity: Identity {
        Identity(pairingID: pairingID, connectionID: connectionID, servesCandidates: candidates != nil)
    }
}

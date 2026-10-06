// SUPERMUX:begin transport-peer-liveness (a device link is judged dead only when its connection shows no life — see SUPERMUX-TOUCHPOINTS.md)
internal import CMUXMobileCore

extension MobileCoreRPCClient {
    /// Whether the peer behind the installed transport shows life on its
    /// native connection (``SupermuxByteTransportPeerActivity``). False when
    /// no transport is installed or the transport cannot tell, so a caller
    /// keeps its own check then.
    public func supermuxPeerShowsLife(since start: ContinuousClock.Instant, probeDeadline: Duration?) async -> Bool {
        await session.supermuxPeerShowsLife(since: start, probeDeadline: probeDeadline)
    }
}

extension MobileCoreRPCSession {
    func supermuxPeerShowsLife(since start: ContinuousClock.Instant, probeDeadline: Duration?) async -> Bool {
        guard let peer = transport as? any SupermuxByteTransportPeerActivity else { return false }
        return await peer.supermuxPeerShowsLife(since: start, probeDeadline: probeDeadline)
    }
}
// SUPERMUX:end transport-peer-liveness

// SUPERMUX:begin irx-route-sample (which path a link uses and iroh's own RTT on it — see SUPERMUX-TOUCHPOINTS.md)
/// The path a connection uses right now, as iroh reports it: relay or IP,
/// its remote address (the relay URL, or the peer's `ip:port`), and QUIC's
/// smoothed round trip on it.
///
/// The RTT is the transport's, measured by QUIC on that path, so it is not
/// inflated by application queueing (the keepalive pong's round trip is).
/// Read with ``IrxConnection/supermuxSelectedPathSample()``; the route a UI
/// shows is classified from it (SupermuxMobileCore's
/// `SupermuxLinkRouteClassifier`).
public struct SupermuxIrxPathSample: Sendable, Equatable {
    /// Whether the selected path goes through a relay.
    public let isRelay: Bool
    /// The relay URL for a relayed path, else the peer's socket address.
    public let remoteAddress: String
    /// QUIC's smoothed round trip on the selected path, in milliseconds.
    public let rttMs: UInt64
    /// How many paths the connection has open (the selected one included).
    public let pathCount: Int
    /// Whether one of them is a relay path (a fallback when direct).
    public let hasRelayPath: Bool

    /// Creates a sample.
    public init(isRelay: Bool, remoteAddress: String, rttMs: UInt64, pathCount: Int, hasRelayPath: Bool) {
        self.isRelay = isRelay
        self.remoteAddress = remoteAddress
        self.rttMs = rttMs
        self.pathCount = pathCount
        self.hasRelayPath = hasRelayPath
    }
}
// SUPERMUX:end irx-route-sample

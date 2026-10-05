// SUPERMUX:begin transport-peer-liveness (a device link is judged dead only when its connection shows no life — see SUPERMUX-TOUCHPOINTS.md)
/// A byte transport that can tell whether the peer behind it still shows
/// life, judged on the whole native connection rather than on one stream.
///
/// A request on the control stream can wait long past its deadline behind
/// bulk replies on a congested link (a relay at 240–400 ms) while the
/// connection keeps delivering the peer's bytes on its other streams. A
/// liveness check sent on that same stream then misses too, and its owner
/// redials a link that was never dead.
public protocol SupermuxByteTransportPeerActivity: CmxByteTransport {
    /// Whether the peer's application layer delivered bytes on any stream of
    /// the native connection since `start`, or, given a `probeDeadline`,
    /// answers a transport keepalive within it.
    ///
    /// `false` alone does not prove the peer dead: a transport that is not
    /// connected yet, or cannot tell, answers `false`, and its owner keeps its
    /// own check.
    func supermuxPeerShowsLife(since start: ContinuousClock.Instant, probeDeadline: Duration?) async -> Bool
}
// SUPERMUX:end transport-peer-liveness

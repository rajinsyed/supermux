// SUPERMUX:begin irx-stream-priority (keepalive and request replies are never starved by terminal output — see SUPERMUX-TOUCHPOINTS.md)
/// Send priorities for the lanes that keep a session alive.
///
/// noq sends a strictly higher-priority stream's buffered data first, and
/// takes turns, packet by packet, between streams of equal priority (send
/// fairness is on by default). Terminal output runs at 100 (the focused
/// surface) and 50 (every other surface, and the shared events lane Mac
/// mirrors use). Left at the default 0, the keepalive pong and every control
/// reply (request answers, replays, the liveness probe's answer) waited behind
/// that output whenever the path was the bottleneck: on a relay the viewer
/// missed its reply deadlines and redialed a link that carried bytes the whole
/// time.
///
/// The ladder, highest first:
/// - keepalive (1000): a ping and its pong are a few bytes every 5 s, so they
///   cannot starve anything, and nothing may starve them.
/// - control and its replacement stream (the focused surface's own 100):
///   request replies take turns with the focused terminal's output. Strictly
///   above it, a multi-MB replay on the control stream would hold the focused
///   terminal's echo for seconds; strictly below, a focused terminal printing
///   without pause would starve every reply.
/// - background terminal output (50) and artifacts (−10) keep their own.
enum SupermuxIrxStreamPriority {
    static let keepalive: Int32 = 1_000
    static let control: Int32 = IrxSurfaceEventLanes.Configuration().focusedPriority

    /// The send priority a lane takes when it opens or is accepted; nil keeps
    /// the stream's default, which its owner may set itself.
    static func priority(for lane: IrxLaneKind) -> Int32? {
        switch lane {
        case .keepalive: keepalive
        case .control, .controlRepair: control
        default: nil
        }
    }
}
// SUPERMUX:end irx-stream-priority

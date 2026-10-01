import Foundation

/// The agent-activity state of a workspace, used to drive a status indicator
/// in the sidebar and tabs.
///
/// Mirrors the three meaningful states piggycode/superset surface, derived from
/// cmux's per-agent ``AgentHibernationLifecycleState`` (running /
/// backgroundWorkPending / needsInput / idle). The visual language
/// (``SupermuxAgentActivityIndicator``):
/// - ``working``: an amber braille spinner — the agent is actively running, or
///   its turn ended with background work still running (cmux's "Waiting":
///   background shells, subagents or scheduled wakeups).
/// - ``needsInput``: a red pulsing dot — the agent is blocked on the user.
/// - ``ready``: a green dot — the agent finished its turn and is awaiting review.
/// - ``idle``: no indicator — no agent activity to surface.
public enum SupermuxWorkspaceActivity: String, Sendable, Hashable, CaseIterable {
    /// No agent activity worth surfacing.
    case idle
    /// An agent is actively working, or waiting on background work it started.
    case working
    /// An agent is blocked waiting for user input.
    case needsInput
    /// An agent finished its turn and is ready for review.
    case ready

    /// Whether this state shows any indicator at all.
    public var isVisible: Bool { self != .idle }

    /// Resolves the activity to surface across a set of per-agent lifecycle
    /// values. `working` wins whenever any agent is running or waiting on its
    /// background work (`backgroundWorkPending`, upstream's "Waiting"), so an
    /// idle sibling's reminder or permission prompt cannot hide an actively
    /// working agent's spinner — the same ranking as upstream's own aggregate.
    /// With no working agent, `needsInput` wins over a finished agent
    /// (`ready`); absent any agent signal the workspace is idle.
    /// - Parameter lifecycles: Raw lifecycle raw-values
    ///   (`"running"`/`"backgroundWorkPending"`/`"needsinput"`/`"needs-input"`/`"idle"`),
    ///   case-insensitive.
    public static func resolve<S: Sequence>(fromLifecycleRawValues lifecycles: S) -> SupermuxWorkspaceActivity
    where S.Element == String {
        var sawRunning = false
        var sawNeedsInput = false
        var sawReady = false
        for raw in lifecycles {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "needsinput", "needs-input": sawNeedsInput = true
            case "running", "backgroundworkpending", "background-work-pending": sawRunning = true
            case "idle": sawReady = true
            default: break
            }
        }
        if sawRunning { return .working }
        if sawNeedsInput { return .needsInput }
        if sawReady { return .ready }
        return .idle
    }
}

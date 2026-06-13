import Foundation

/// The agent-activity state of a workspace, used to drive a status indicator
/// in the sidebar and tabs.
///
/// Mirrors the three meaningful states piggycode/superset surface, derived from
/// cmux's per-agent ``AgentHibernationLifecycleState`` (running / needsInput /
/// idle). The visual language (``SupermuxAgentActivityIndicator``):
/// - ``working``: an amber braille spinner — the agent is actively running.
/// - ``needsInput``: a red pulsing dot — the agent is blocked on the user.
/// - ``ready``: a green dot — the agent finished its turn and is awaiting review.
/// - ``idle``: no indicator — no agent activity to surface.
public enum SupermuxWorkspaceActivity: String, Sendable, Hashable, CaseIterable {
    /// No agent activity worth surfacing.
    case idle
    /// An agent is actively working.
    case working
    /// An agent is blocked waiting for user input.
    case needsInput
    /// An agent finished its turn and is ready for review.
    case ready

    /// Whether this state shows any indicator at all.
    public var isVisible: Bool { self != .idle }

    /// Resolves the most urgent activity across a set of per-agent lifecycle
    /// values. `needsInput` wins (the user must act), then `working`, then a
    /// finished agent (`ready`); absent any agent signal the workspace is idle.
    /// - Parameter lifecycles: Raw lifecycle raw-values
    ///   (`"running"`/`"needsinput"`/`"needs-input"`/`"idle"`), case-insensitive.
    public static func resolve<S: Sequence>(fromLifecycleRawValues lifecycles: S) -> SupermuxWorkspaceActivity
    where S.Element == String {
        var sawRunning = false
        var sawReady = false
        for raw in lifecycles {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "needsinput", "needs-input": return .needsInput
            case "running": sawRunning = true
            case "idle": sawReady = true
            default: break
            }
        }
        if sawRunning { return .working }
        if sawReady { return .ready }
        return .idle
    }
}

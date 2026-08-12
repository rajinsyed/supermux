/// A `supermux.*` event topic the macOS host publishes over the existing
/// `mobile.events.subscribe` pub/sub plane.
///
/// Most events are payload-light "pokes" that make the phone refetch through
/// the matching RPC. ``claudeEvent`` is the exception: it carries a compact,
/// monotonic transcript frame.
public enum SupermuxMobileTopic: String, CaseIterable, Codable, Sendable, Equatable {
    /// The projects model changed; refetch via ``SupermuxMobileMethod/projectsList``.
    case projectsUpdated = "supermux.projects.updated"
    /// A project's worktrees changed; refetch via ``SupermuxMobileMethod/worktreesList``.
    case worktreesUpdated = "supermux.worktrees.updated"
    /// A watched workspace's repository changed (payload `{workspace_id}`);
    /// refetch via ``SupermuxMobileMethod/changesStatus``.
    case changesUpdated = "supermux.changes.updated"
    /// A project's run state changed; refetch via ``SupermuxMobileMethod/runState``.
    case runUpdated = "supermux.run.updated"
    /// Claude session metadata changed; refetch via ``SupermuxMobileMethod/claudeSessionsList``.
    case claudeSessionsUpdated = "supermux.claude.sessions_updated"
    /// Carries a ``SupermuxClaudeEventFrame`` for a watched Claude session.
    case claudeEvent = "supermux.claude.event"

    /// Every topic, in declaration order (derived from `CaseIterable`).
    public static let all: [SupermuxMobileTopic] = SupermuxMobileTopic.allCases
}

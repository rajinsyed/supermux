/// A `supermux.*` event topic the macOS host publishes over the existing
/// `mobile.events.subscribe` pub/sub plane.
///
/// Events are payload-light "pokes" — the phone refetches through the matching
/// RPC method on receipt (same pattern as `workspace.updated`).
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

    /// Every topic, in declaration order (derived from `CaseIterable`).
    public static let all: [SupermuxMobileTopic] = SupermuxMobileTopic.allCases
}

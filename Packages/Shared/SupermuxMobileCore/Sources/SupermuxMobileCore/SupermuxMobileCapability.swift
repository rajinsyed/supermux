/// A capability identifier the supermux macOS host advertises so the phone
/// can gate its UI.
///
/// Every iOS entry point stays hidden unless the host advertises the matching
/// capability — a fork phone paired with upstream cmux renders exactly
/// today's UI.
public enum SupermuxMobileCapability: String, CaseIterable, Codable, Sendable, Equatable {
    /// Projects list/CRUD/open/icon methods are served.
    case projectsV1 = "supermux.projects.v1"
    /// Workspace-list payloads may carry `supermux_activity`.
    case activityV1 = "supermux.activity.v1"
    /// Worktree list/create/open/remove methods are served.
    case worktreesV1 = "supermux.worktrees.v1"
    /// Terminal-preset CRUD/launch methods are served.
    case presetsV1 = "supermux.presets.v1"
    /// Changes (git) methods and the changes watcher are served.
    case changesV1 = "supermux.changes.v1"
    /// Run state/start/stop methods are served.
    case runV1 = "supermux.run.v1"
    /// Project-action execution is served.
    case actionsV1 = "supermux.actions.v1"
    /// File-browser methods are served.
    case filesV1 = "supermux.files.v1"

    /// Every capability, in declaration order (derived from `CaseIterable`).
    public static let all: [SupermuxMobileCapability] = SupermuxMobileCapability.allCases
}

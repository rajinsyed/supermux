/// What a project row's worktree pill ("⑂ N ›") shows: how many worktrees
/// the disclosure would reveal, and whether the pill is drawn at all. The
/// pill shows only when there is an unopened worktree to reveal, on this Mac
/// or another one, and always with its number. The main checkout never
/// counts, nor does a worktree already open here (or open on its Mac and
/// mirrored here). The rows and the DEBUG `projects_presentation` socket
/// payload both build it here, so a test reads exactly what the sidebar draws.
public struct SupermuxWorktreeDisclosure: Equatable, Sendable {
    /// This Mac's unopened worktrees plus the other Macs' unopened ones.
    public let count: Int
    /// Whether the row draws the pill.
    public let isShown: Bool

    /// A local project's row: its worktrees on this Mac that have no open
    /// workspace here, plus the device copies' unopened worktrees in `extras`
    /// (offline Macs' included: they stay listed, dimmed).
    /// - Parameters:
    ///   - worktrees: This Mac's worktrees of the project (main checkout excluded).
    ///   - openWorkspaces: The workspaces nested under the project row.
    ///   - extras: The project's other-Mac parts, if it has any.
    public init(
        worktrees: [SupermuxProjectWorktree],
        openWorkspaces: [SupermuxOpenWorkspace],
        extras: SupermuxProjectRemoteExtras?
    ) {
        let openDirectories = SupermuxUnopenedWorktrees.openDirectories(openWorkspaces)
        self.init(unopened: SupermuxUnopenedWorktrees.filter(worktrees, openDirectories: openDirectories), extras: extras)
    }

    /// A local project's row from its precomputed unopened worktrees.
    init(unopened: [SupermuxProjectWorktree], extras: SupermuxProjectRemoteExtras?) {
        count = unopened.count + (extras?.worktrees.count ?? 0)
        isShown = count > 0
    }

    /// A project that exists only on another Mac: that Mac's unopened
    /// worktrees, offered while it is online.
    public init(remoteOnly row: SupermuxRemoteProjectRow) {
        count = row.worktrees.count
        isShown = row.location.isOnline && count > 0
    }
}

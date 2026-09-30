public import Foundation

/// An immutable snapshot of a live cmux workspace, used to render the
/// workspaces that belong to a project nested under it in the sidebar.
///
/// The host app (which owns the real `TabManager`) builds these from its open
/// workspaces and hands them to ``SupermuxProjectsSectionView``; the package
/// matches each to a project by directory (``SupermuxProjectMatcher``) and
/// renders it as a child row. Selecting or closing a row calls back into the
/// host — the package never touches app types.
public struct SupermuxOpenWorkspace: Identifiable, Hashable, Sendable {
    /// The cmux workspace identifier.
    public let id: UUID
    /// Display title (the workspace's custom title or process title).
    public let title: String
    /// Absolute working directory (normalized by the host).
    public let directory: String
    /// Whether this workspace is the currently selected one.
    public let isSelected: Bool
    /// The workspace's git branch, when known, for a subtitle.
    public let branch: String?
    /// The project this workspace nests under, or `nil` to keep it standalone
    /// in the flat list. Resolved by the host from explicit project-association
    /// (opened from a project) or worktree directory — never from a bare
    /// directory-containment guess, so a workspace that merely inherited a
    /// project's directory stays standalone.
    public let projectId: UUID?
    /// The workspace's agent activity, for the status indicator.
    public let activity: SupermuxWorkspaceActivity
    /// Whether this workspace's project run command is currently running,
    /// for the piggycode-style run indicator on the row.
    public let isRunning: Bool
    /// The pull request for this workspace's branch, when cmux has probed one.
    /// Reused directly from cmux's own per-workspace PR state (the host maps
    /// `Workspace.sidebarPullRequestsInDisplayOrder().first`), so no separate
    /// probe runs for opened worktrees.
    public let pullRequest: SupermuxPullRequest?
    /// The workspace's displayed unread count — the same per-workspace value
    /// cmux's flat sidebar rows badge (notification unread plus the
    /// manual/panel-derived/restored indicator), so a workspace shows one
    /// number whether it renders flat or nested under a project.
    public let unreadCount: Int
    /// The Mac this workspace mirrors when it is a device mirror (a local
    /// workspace showing another Mac's workspace), for the row's device chip;
    /// `nil` for this Mac's own workspaces.
    public let device: SupermuxProjectDevice?
    /// The `cmux set-status` pills the row shows (a mirror's come from its
    /// Mac), without the agent pills the activity indicator already shows.
    public let statusPills: [SupermuxRowStatusPill]
    /// The `cmux set-progress` bar the row shows, if any.
    public let progress: SupermuxRowProgress?

    /// Creates a snapshot.
    /// - Parameters:
    ///   - id: The cmux workspace identifier.
    ///   - title: Display title.
    ///   - directory: Absolute working directory.
    ///   - isSelected: Whether it is the active workspace.
    ///   - branch: Current git branch, if known.
    ///   - projectId: Owning project for nesting, or `nil` if standalone.
    ///   - activity: Agent activity state for the indicator.
    ///   - isRunning: Whether the project run command is active for this workspace.
    ///   - pullRequest: The workspace branch's pull request, if cmux probed one.
    ///   - unreadCount: The row's displayed unread count (0 hides the badge).
    ///   - device: The Mac a device mirror shows, or `nil` for a local workspace.
    ///   - statusPills: The status pills to show under the title.
    ///   - progress: The progress bar to show under the title, if any.
    public init(
        id: UUID,
        title: String,
        directory: String,
        isSelected: Bool,
        branch: String? = nil,
        projectId: UUID? = nil,
        activity: SupermuxWorkspaceActivity = .idle,
        isRunning: Bool = false,
        pullRequest: SupermuxPullRequest? = nil,
        unreadCount: Int = 0,
        device: SupermuxProjectDevice? = nil,
        statusPills: [SupermuxRowStatusPill] = [],
        progress: SupermuxRowProgress? = nil
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.isSelected = isSelected
        self.branch = branch
        self.projectId = projectId
        self.activity = activity
        self.isRunning = isRunning
        self.pullRequest = pullRequest
        self.unreadCount = unreadCount
        self.device = device
        self.statusPills = statusPills
        self.progress = progress
    }

    /// The row's VoiceOver label: the title, plus the Mac a device mirror
    /// runs on ("api on MacBook Pro"), as flat mirror rows announce theirs.
    public var accessibilityLabel: String {
        guard let device else { return title }
        return String(localized: "supermux.workspace.accessibility.onMac", defaultValue: "\(title) on \(device.name)")
    }
}

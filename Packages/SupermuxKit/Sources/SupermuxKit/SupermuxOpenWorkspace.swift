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
    public init(
        id: UUID,
        title: String,
        directory: String,
        isSelected: Bool,
        branch: String? = nil,
        projectId: UUID? = nil,
        activity: SupermuxWorkspaceActivity = .idle,
        isRunning: Bool = false
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.isSelected = isSelected
        self.branch = branch
        self.projectId = projectId
        self.activity = activity
        self.isRunning = isRunning
    }
}

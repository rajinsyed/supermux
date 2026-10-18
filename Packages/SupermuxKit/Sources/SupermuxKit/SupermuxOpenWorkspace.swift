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
    /// The workspace's displayed unread count — the same per-workspace value
    /// cmux's flat sidebar rows badge (notification unread plus the
    /// manual/panel-derived/restored indicator), so a workspace shows one
    /// number whether it renders flat or nested under a project.
    public let unreadCount: Int
    /// The Mac this workspace mirrors when it is a device mirror (a local
    /// workspace showing another Mac's workspace), for the row's Mac icon;
    /// `nil` for this Mac's own workspaces.
    public let device: SupermuxProjectDevice?
    /// The block of nested rows this row is ordered and dragged within:
    /// ``orderedGroup`` for every row that follows the shared order (this
    /// Mac's own workspaces and the mirrors whose owner keys them), otherwise
    /// the machine id of the older Mac an unkeyed mirror shows, whose rows
    /// stay one block per Mac.
    public let orderGroup: String

    /// The ``orderGroup`` of every row in the shared order.
    public static let orderedGroup = "ordered"

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
    ///   - unreadCount: The row's displayed unread count (0 hides the badge).
    ///   - device: The Mac a device mirror shows, or `nil` for a local workspace.
    ///   - orderGroup: The block the row is ordered and dragged within;
    ///     defaults to ``orderedGroup`` (the shared order).
    public init(
        id: UUID,
        title: String,
        directory: String,
        isSelected: Bool,
        branch: String? = nil,
        projectId: UUID? = nil,
        activity: SupermuxWorkspaceActivity = .idle,
        isRunning: Bool = false,
        unreadCount: Int = 0,
        device: SupermuxProjectDevice? = nil,
        orderGroup: String = Self.orderedGroup
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.isSelected = isSelected
        self.branch = branch
        self.projectId = projectId
        self.activity = activity
        self.isRunning = isRunning
        self.unreadCount = unreadCount
        self.device = device
        self.orderGroup = orderGroup
    }

    /// The row's VoiceOver label: the title, plus the Mac a device mirror
    /// runs on ("api on MacBook Pro"), as flat mirror rows announce theirs.
    public var accessibilityLabel: String {
        guard let device else { return title }
        return String(localized: "supermux.workspace.accessibility.onMac", defaultValue: "\(title) on \(device.name)")
    }

    /// The branch line the row shows, if any (an empty branch shows none).
    public var displayedBranch: String? {
        guard let branch, !branch.isEmpty else { return nil }
        return branch
    }

    /// Where the row draws its Mac's icon: right before the branch name, or
    /// before the title when it shows no branch; `nil` for this Mac's own
    /// workspaces, which draw none.
    public var deviceIconPlacement: SupermuxDeviceIconPlacement? {
        guard device != nil else { return nil }
        return displayedBranch == nil ? .beforeTitle : .beforeBranch
    }
}

/// Where a nested workspace row draws the icon of the Mac it lives on.
public enum SupermuxDeviceIconPlacement: Sendable {
    /// Right before the branch name.
    case beforeBranch
    /// Right before the title (the row shows no branch).
    case beforeTitle
}

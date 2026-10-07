import Foundation

/// A git worktree of a project copy on another Mac (from that Mac's
/// `worktrees.list`), shown as an unopened worktree row with a device chip.
public struct SupermuxRemoteWorktree: Identifiable, Hashable, Sendable {
    /// The copy the worktree belongs to (device, that Mac's project id, root).
    public let location: SupermuxProjectLocation
    /// Absolute worktree path on that Mac.
    public let path: String
    /// Checked-out branch, or `nil` when detached.
    public let branch: String?
    /// Whether the worktree has uncommitted changes (known at list time).
    public let isDirty: Bool

    /// Creates a remote worktree row value.
    public init(
        location: SupermuxProjectLocation,
        path: String,
        branch: String?,
        isDirty: Bool = false
    ) {
        self.location = location
        self.path = path
        self.branch = branch
        self.isDirty = isDirty
    }

    /// Unique per Mac, project and path.
    public var id: String { "\(location.id)|\(path)" }

    /// The branch name, or the path's last component when detached.
    public var displayName: String {
        branch ?? (path as NSString).lastPathComponent
    }
}

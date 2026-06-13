import Foundation

/// A git worktree discovered for a project.
///
/// Worktrees are never persisted by supermux — git's `worktree list` is the
/// single source of truth, so externally created worktrees show up too and
/// stale records cannot accumulate. ``isSupermuxManaged`` marks worktrees that
/// live under the project's worktrees directory; only those may be deleted
/// from the supermux UI.
public struct SupermuxProjectWorktree: Identifiable, Hashable, Sendable {
    /// Absolute path of the worktree checkout (also the stable identity).
    public let path: String
    /// The branch checked out in this worktree, or `nil` for a detached HEAD.
    public let branch: String?
    /// Whether the worktree lives under the project's worktrees directory.
    public let isSupermuxManaged: Bool

    /// The worktree path doubles as its identity.
    public var id: String { path }

    /// Creates a worktree description.
    /// - Parameters:
    ///   - path: Absolute checkout path.
    ///   - branch: Checked-out branch, or `nil` when detached.
    ///   - isSupermuxManaged: Whether supermux owns the worktree's location.
    public init(path: String, branch: String?, isSupermuxManaged: Bool) {
        self.path = path
        self.branch = branch
        self.isSupermuxManaged = isSupermuxManaged
    }

    /// A short display label: the branch name, or the path basename when detached.
    public var displayName: String {
        branch ?? (path as NSString).lastPathComponent
    }
}

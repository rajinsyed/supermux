import Foundation

/// The single definition of "does this worktree already have an open
/// workspace?" — shared by the sidebar's PR-probe target computation
/// (`SupermuxProjectsSectionView+PullRequests.swift`) and the project row's
/// unopened-worktree disclosure (`SupermuxProjectRowView`), so the two can
/// never drift apart.
///
/// Today's rule compares `(path as NSString).standardizingPath` on both sides
/// (workspace directory and worktree path). This is intentionally the one
/// place to later reconcile with ``SupermuxWorktreePath/canonical(_:)`` for
/// symlinked host directories, should the standardized form ever mismatch a
/// symlink-resolved live workspace directory.
enum SupermuxUnopenedWorktrees {
    /// The standardized directories of the given open workspaces, for
    /// membership tests via ``isOpen(_:openDirectories:)``.
    static func openDirectories(_ workspaces: [SupermuxOpenWorkspace]) -> Set<String> {
        Set(workspaces.map { ($0.directory as NSString).standardizingPath })
    }

    /// Whether the worktree's standardized path matches an open workspace
    /// directory from ``openDirectories(_:)``.
    static func isOpen(_ worktree: SupermuxProjectWorktree, openDirectories: Set<String>) -> Bool {
        openDirectories.contains((worktree.path as NSString).standardizingPath)
    }

    /// The worktrees that do not already have an open workspace.
    static func filter(
        _ worktrees: [SupermuxProjectWorktree],
        openDirectories: Set<String>
    ) -> [SupermuxProjectWorktree] {
        worktrees.filter { !isOpen($0, openDirectories: openDirectories) }
    }
}

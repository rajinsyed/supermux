import Foundation
public import SupermuxMobileCore

extension SupermuxWorktreeDTO {
    /// Maps a Mac-side worktree record (plus its open-workspace context,
    /// resolved by the caller) onto its wire DTO.
    /// - Parameters:
    ///   - worktree: The worktree discovered from git.
    ///   - isOpen: Whether a workspace is currently open in this worktree.
    ///   - workspaceId: The open workspace's id, when `isOpen` is true.
    public init(
        worktree: SupermuxProjectWorktree,
        isOpen: Bool,
        workspaceId: String? = nil
    ) {
        self.init(
            path: worktree.path,
            branch: worktree.branch,
            isOpen: isOpen,
            workspaceId: workspaceId
        )
    }
}

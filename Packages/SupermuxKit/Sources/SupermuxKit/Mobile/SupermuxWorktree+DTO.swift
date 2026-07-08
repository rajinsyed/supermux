public import Foundation
public import SupermuxMobileCore

extension SupermuxPullRequestDTO {
    /// Maps a Mac-side pull-request badge value onto its wire DTO.
    ///
    /// `state` travels as the shared raw string (`"open"`/`"merged"`/`"closed"`);
    /// `title` is forwarded when the source carries one (cmux's probe pipeline
    /// does not surface titles today, so production values may omit it — the
    /// field is optional on the wire).
    /// - Parameter pullRequest: The Mac-side badge value.
    public init(pullRequest: SupermuxPullRequest) {
        self.init(
            number: pullRequest.number,
            state: pullRequest.status.rawValue,
            title: pullRequest.title,
            url: pullRequest.url.absoluteString
        )
    }
}

extension SupermuxWorktreeDTO {
    /// Maps a Mac-side worktree record (plus its open-workspace and
    /// pull-request context, resolved by the caller) onto its wire DTO.
    /// - Parameters:
    ///   - worktree: The worktree discovered from git.
    ///   - isOpen: Whether a workspace is currently open in this worktree.
    ///   - workspaceId: The open workspace's id, when `isOpen` is true.
    ///   - pullRequest: The associated pull request, when one is known.
    public init(
        worktree: SupermuxProjectWorktree,
        isOpen: Bool,
        workspaceId: String? = nil,
        pullRequest: SupermuxPullRequest? = nil
    ) {
        self.init(
            path: worktree.path,
            branch: worktree.branch,
            isOpen: isOpen,
            workspaceId: workspaceId,
            pullRequest: pullRequest.map(SupermuxPullRequestDTO.init(pullRequest:))
        )
    }
}

public import Foundation
internal import SupermuxMobileCore

/// Builds the `mobile.supermux.worktrees.list` result payload
/// (`{worktrees: [SupermuxWorktreeDTO]}`).
///
/// Lives in SupermuxKit (not the app target) so the wire shape — including
/// the pull-request fold and open-workspace matching — is package-unit-testable;
/// the app handler stays a thin pass-through reading `SupermuxComposition`.
///
/// Pull-request precedence mirrors the desktop sidebar exactly: a worktree
/// with an open workspace uses that workspace's own PR (cmux's per-workspace
/// probe, carried on ``SupermuxOpenWorkspace/pullRequest``); unopened
/// worktrees fall back to ``SupermuxWorktreePullRequestModel``'s badge map.
/// Open matching uses the same standardized-path rule as
/// ``SupermuxUnopenedWorktrees`` so the two surfaces can never drift apart.
public struct SupermuxMobileWorktreesPayloadBuilder: Sendable {
    /// Creates a builder. Stateless; construct wherever needed.
    public init() {}

    /// Encodes the worktrees-list result payload.
    /// - Parameters:
    ///   - worktrees: The project's worktrees in `git worktree list` order.
    ///   - openWorkspaces: Snapshots of every open workspace (all windows);
    ///     matched to worktrees by standardized directory.
    ///   - pullRequestsByWorktreePath: The unopened-worktree PR badge map
    ///     (``SupermuxWorktreePullRequestModel/pullRequestsByWorktreePath``).
    /// - Returns: The RPC result object (`worktrees`).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func worktreesList(
        worktrees: [SupermuxProjectWorktree],
        openWorkspaces: [SupermuxOpenWorkspace],
        pullRequestsByWorktreePath: [String: SupermuxPullRequest]
    ) throws -> [String: Any] {
        let wire = SupermuxWireJSON()
        // First workspace per standardized directory wins, matching
        // `SupermuxUnopenedWorktrees.openDirectories`' membership rule.
        var workspacesByDirectory: [String: SupermuxOpenWorkspace] = [:]
        for workspace in openWorkspaces {
            let key = (workspace.directory as NSString).standardizingPath
            if workspacesByDirectory[key] == nil {
                workspacesByDirectory[key] = workspace
            }
        }
        let encoded = try worktrees.map { worktree -> [String: Any] in
            let openWorkspace = workspacesByDirectory[(worktree.path as NSString).standardizingPath]
            let pullRequest = openWorkspace?.pullRequest ?? pullRequestsByWorktreePath[worktree.path]
            return try wire.dictionary(from: SupermuxWorktreeDTO(
                worktree: worktree,
                isOpen: openWorkspace != nil,
                workspaceId: openWorkspace?.id.uuidString,
                pullRequest: pullRequest
            ))
        }
        return ["worktrees": encoded]
    }
}

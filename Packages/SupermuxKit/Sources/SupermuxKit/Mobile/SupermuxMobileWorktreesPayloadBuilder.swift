import Foundation
internal import SupermuxMobileCore

/// Builds the `mobile.supermux.worktrees.list` result payload.
///
/// The always-present shape is `{worktrees: [SupermuxWorktreeDTO]}`. A caller
/// explicitly preparing the starting-branch picker may also include
/// `branches: [String]`; ordinary list/count refreshes omit it.
///
/// Lives in SupermuxKit (not the app target) so the wire shape — including
/// open-workspace matching — is package-unit-testable; the app handler stays
/// a thin pass-through reading `SupermuxComposition`.
///
/// Open matching uses the same standardized-path rule as
/// ``SupermuxUnopenedWorktrees`` so the two surfaces can never drift apart.
public struct SupermuxMobileWorktreesPayloadBuilder: Sendable {
    /// Creates a builder. Stateless; construct wherever needed.
    public init() {}

    /// Encodes the worktrees-list result payload.
    /// - Parameters:
    ///   - worktrees: The project's worktrees in `git worktree list` order.
    ///   - branches: Local branches available as starting points, or `nil` to
    ///     omit branch discovery from this response.
    ///   - openWorkspaces: Snapshots of every open workspace (all windows);
    ///     matched to worktrees by standardized directory.
    /// - Returns: The RPC result object (`worktrees`, plus `branches` when requested).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func worktreesList(
        worktrees: [SupermuxProjectWorktree],
        branches: [String]? = nil,
        openWorkspaces: [SupermuxOpenWorkspace]
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
            return try wire.dictionary(from: SupermuxWorktreeDTO(
                worktree: worktree,
                isOpen: openWorkspace != nil,
                workspaceId: openWorkspace?.id.uuidString
            ))
        }
        var payload: [String: Any] = ["worktrees": encoded]
        if let branches {
            payload["branches"] = branches
        }
        return payload
    }
}

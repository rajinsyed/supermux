import Foundation
internal import SupermuxMobileCore

/// Builds the `mobile.supermux.changes.status` and `changes.diff` result
/// payloads.
///
/// Lives in SupermuxKit (not the app target) so the wire shape — the
/// snapshot → `SupermuxChangesStatusDTO` mapping and the diff capture →
/// `SupermuxDiffDTO` mapping — is package-unit-testable; the app handler
/// stays a thin pass-through that resolves the workspace and calls
/// ``SupermuxGitChangesService``.
public struct SupermuxMobileChangesPayloadBuilder: Sendable {
    /// Creates a builder. Stateless; construct wherever needed.
    public init() {}

    /// Encodes the changes-status result payload from a git status snapshot.
    /// - Parameters:
    ///   - workspaceId: The workspace the snapshot describes (echoed back).
    ///   - snapshot: The parsed `git status` snapshot.
    /// - Returns: The RPC result object (`SupermuxChangesStatusDTO` shape).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func status(
        workspaceId: String,
        snapshot: SupermuxGitStatusSnapshot
    ) throws -> [String: Any] {
        try SupermuxWireJSON().dictionary(from: SupermuxChangesStatusDTO(
            workspaceId: workspaceId,
            isRepository: snapshot.isRepository,
            branch: snapshot.branch,
            upstreamBranch: snapshot.upstreamBranch,
            ahead: snapshot.ahead,
            behind: snapshot.behind,
            staged: snapshot.staged.map(Self.changedFile),
            unstaged: snapshot.unstaged.map(Self.changedFile),
            untracked: snapshot.untracked.map(Self.changedFile),
            stashCount: snapshot.stashEntryCount
        ))
    }

    /// Encodes the changes-diff result payload from a captured file diff.
    /// - Parameters:
    ///   - path: Repo-relative path that was diffed (echoed back).
    ///   - diff: The captured diff.
    /// - Returns: The RPC result object (`SupermuxDiffDTO` shape).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func diff(path: String, diff: SupermuxGitFileDiff) throws -> [String: Any] {
        try SupermuxWireJSON().dictionary(from: SupermuxDiffDTO(
            path: path,
            isBinary: diff.isBinary,
            diffText: diff.text,
            truncated: diff.truncated
        ))
    }

    /// Maps one parsed file change to its wire DTO.
    private static func changedFile(_ change: SupermuxGitFileChange) -> SupermuxChangedFileDTO {
        SupermuxChangedFileDTO(
            path: change.path,
            oldPath: change.oldPath,
            kind: change.kind.rawValue
        )
    }
}

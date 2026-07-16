import Foundation
internal import SupermuxMobileCore

/// Builds the `mobile.supermux.changes.status`, `changes.diff`, sync
/// (`changes.push`/`pull`/`stash`/`stash_pop`), and `changes.history` result
/// payloads.
///
/// Lives in SupermuxKit (not the app target) so the wire shapes — the
/// snapshot → `SupermuxChangesStatusDTO` mapping, the diff capture →
/// `SupermuxDiffDTO` mapping, the sync-log `{ok, log_lines}` object, and the
/// history page's `SupermuxCommitDTO` arrays with sha-cursor pagination —
/// are package-unit-testable; the app handler stays a thin pass-through that
/// resolves the workspace and calls ``SupermuxGitChangesService``.
public struct SupermuxMobileChangesPayloadBuilder: Sendable {
    /// Creates a builder. Stateless; construct wherever needed.
    public init() {}

    /// Encodes the changes-status result payload from a git status snapshot.
    /// - Parameters:
    ///   - workspaceId: The workspace the snapshot describes (echoed back).
    ///   - snapshot: The parsed `git status` snapshot.
    ///   - root: The workspace's live repository root, echoed so the phone can
    ///     pin `expected_root` on mutations against a stale view.
    /// - Returns: The RPC result object (`SupermuxChangesStatusDTO` shape).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func status(
        workspaceId: String,
        snapshot: SupermuxGitStatusSnapshot,
        root: String? = nil
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
            stashCount: snapshot.stashEntryCount,
            root: root
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

    /// Encodes the result payload for one sync mutation (`changes.push` /
    /// `changes.pull` / `changes.stash` / `changes.stash_pop`):
    /// `{ok: true, log_lines: [String], log_truncated?: true}` —
    /// `log_truncated` travels only when the caps in
    /// ``SupermuxMobileSyncLog`` dropped output (additive optional, so old
    /// peers ignore it).
    /// - Parameter log: The bounded git-output capture.
    /// - Returns: The RPC result object.
    public func sync(log: SupermuxMobileSyncLogCapture) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true,
            "log_lines": log.lines,
        ]
        if log.truncated {
            payload["log_truncated"] = true
        }
        return payload
    }

    /// Encodes the `changes.history` result payload:
    /// `{commits: [SupermuxCommitDTO], incoming: [SupermuxCommitDTO],
    /// next_cursor?: String}`.
    ///
    /// `localCommits` is the raw page read with `limit + 1` entries so this
    /// builder can detect a further page: when more than `limit` commits
    /// arrived, the payload carries `nextCursor` (the caller-computed resume
    /// token — see the handler's compound `<root-sha>.<offset>` cursor).
    /// `is_pushed` is `false` exactly for the shas in `unpushedShas`; incoming
    /// (pullable) commits are on the upstream by definition and travel with
    /// `is_pushed: true`.
    /// - Parameters:
    ///   - localCommits: Up to `limit + 1` local history commits, newest first.
    ///   - limit: The requested page size.
    ///   - unpushedShas: Full shas of commits not yet on the remote.
    ///   - incoming: Pullable upstream commits (first page only).
    ///   - nextCursor: The resume token to emit when a further page exists.
    /// - Returns: The RPC result object.
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func history(
        localCommits: [SupermuxGitCommit],
        limit: Int,
        unpushedShas: Set<String>,
        incoming: [SupermuxGitCommit],
        nextCursor: String
    ) throws -> [String: Any] {
        let wire = SupermuxWireJSON()
        let page = localCommits.prefix(limit)
        var payload: [String: Any] = [
            "commits": try page.map {
                try wire.dictionary(from: Self.commit($0, isPushed: !unpushedShas.contains($0.hash)))
            },
            "incoming": try incoming.map {
                try wire.dictionary(from: Self.commit($0, isPushed: true))
            },
        ]
        if localCommits.count > limit {
            payload["next_cursor"] = nextCursor
        }
        return payload
    }

    /// Maps one parsed commit to its wire DTO.
    private static func commit(
        _ commit: SupermuxGitCommit, isPushed: Bool
    ) -> SupermuxCommitDTO {
        SupermuxCommitDTO(
            sha: commit.hash,
            shortSha: commit.shortHash,
            author: commit.author,
            relativeDate: commit.relativeDate,
            subject: commit.subject,
            isPushed: isPushed
        )
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

import AppKit
import CmuxFoundation
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.changes.*` handlers (part 2: commit /
/// generate_commit_message / push / pull / stash / stash_pop / history): the
/// sync half of the iOS Changes screen. Shares the process-wide
/// ``SupermuxGitChangesService`` and workspace resolution with
/// `SupermuxMobileHost+Changes.swift`; wire payloads are built by
/// package-tested SupermuxKit types.
///
/// Deadlines: the mac RPC pipeline has no server-side per-method deadline —
/// a handler runs until it returns and the reply frame is written then. Push
/// and pull are bounded only by the service's 120 s git network timeout,
/// which exceeds the phone's 30 s default request deadline
/// (`CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds`); the iOS client
/// MUST pass an extended per-request `timeoutNanoseconds` (≥ 130 s) through
/// `MobileCoreRPCClient.sendRequest` for `changes.push` / `changes.pull`.
extension TerminalController {
    /// Default `changes.history` page size (half the desktop feed page, sized
    /// for a phone screen).
    private static let supermuxHistoryDefaultLimit = 50
    /// Upper bound a caller-supplied `limit` is clamped to.
    private static let supermuxHistoryMaxLimit = 200
    /// Cap on the unpushed-sha probe that drives `is_pushed` flags. Unpushed
    /// commits are the branch's "ahead" set — normally small; in a
    /// never-pushed repository deeper than this, commits beyond the cap
    /// degrade to `is_pushed: true`.
    private static let supermuxHistoryUnpushedProbeLimit = 1000

    /// `mobile.supermux.changes.commit`: commits the staged changes with
    /// `{message}`, staging everything first when `{stage_all: true}` (the
    /// desktop's AI-commit staging behavior). Result: `{sha}` — the new
    /// `HEAD` commit.
    @MainActor
    func v2SupermuxChangesCommit(params: [String: Any]) async -> V2CallResult {
        let target: (workspaceId: String, directory: String)
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return error
        case let .success(resolved): target = resolved
        }
        guard let message = (params["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return .err(
                code: "invalid_params", message: "message must be a non-empty string", data: nil
            )
        }
        let service = Self.supermuxMobileChangesService
        do {
            if params["stage_all"] as? Bool == true {
                try await service.stageAll(repoPath: target.directory)
            }
            try await service.commit(repoPath: target.directory, message: message)
        } catch {
            return .err(code: "unavailable", message: error.localizedDescription, data: nil)
        }
        guard let sha = await service.headCommitSha(repoPath: target.directory) else {
            return .err(code: "unavailable", message: "Failed to read the new commit", data: nil)
        }
        return .ok(["sha": sha])
    }

    /// `mobile.supermux.changes.generate_commit_message`: an AI-written
    /// message for the uncommitted changes (mac-side only; the key and model
    /// never travel in any payload). No configured key — or a failed
    /// generation — is the `ai_unavailable` error, never a silent empty
    /// message. Result: `{message}`.
    @MainActor
    func v2SupermuxChangesGenerateCommitMessage(params: [String: Any]) async -> V2CallResult {
        let target: (workspaceId: String, directory: String)
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return error
        case let .success(resolved): target = resolved
        }
        switch await SupermuxMobileCommitMessage.generate(
            repoPath: target.directory,
            service: Self.supermuxMobileChangesService,
            messenger: SupermuxComposition.aiCommitMessenger
        ) {
        case .unavailable:
            return .err(
                code: "ai_unavailable", message: "No AI Gateway key is configured", data: nil
            )
        case .failed:
            return .err(
                code: "ai_unavailable", message: "Could not generate a commit message", data: nil
            )
        case .nothingToDescribe:
            return .err(code: "unavailable", message: "Nothing to commit", data: nil)
        case let .generated(message):
            return .ok(["message": message])
        }
    }

    /// `mobile.supermux.changes.push`: pushes the current branch (setting an
    /// upstream on the first push, like the desktop). Result:
    /// `{ok, log_lines, log_truncated?}`. Long-running — see the extension
    /// doc's deadline note.
    @MainActor
    func v2SupermuxChangesPush(params: [String: Any]) async -> V2CallResult {
        await supermuxChangesSyncMutation(params: params) { directory, service in
            let hasUpstream = await service.status(repoPath: directory).upstreamBranch != nil
            return try await service.push(repoPath: directory, hasUpstream: hasUpstream)
        }
    }

    /// `mobile.supermux.changes.pull`: pulls from the configured upstream.
    /// Result: `{ok, log_lines, log_truncated?}`. Long-running — see the
    /// extension doc's deadline note.
    @MainActor
    func v2SupermuxChangesPull(params: [String: Any]) async -> V2CallResult {
        await supermuxChangesSyncMutation(params: params) { directory, service in
            try await service.pull(repoPath: directory)
        }
    }

    /// `mobile.supermux.changes.stash`: stashes working-tree changes with an
    /// optional `{message}`, including untracked files when
    /// `{include_untracked: true}` (the desktop's two stash menu items).
    /// Result: `{ok, log_lines, log_truncated?}`.
    @MainActor
    func v2SupermuxChangesStash(params: [String: Any]) async -> V2CallResult {
        let message = (params["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let includeUntracked = params["include_untracked"] as? Bool ?? false
        return await supermuxChangesSyncMutation(params: params) { directory, service in
            try await service.stash(
                repoPath: directory,
                includeUntracked: includeUntracked,
                message: message
            )
        }
    }

    /// `mobile.supermux.changes.stash_pop`: restores and drops the most
    /// recent stash. A conflicting pop surfaces git's error (the stash stays
    /// in place, conflicts appear in the next status). Result:
    /// `{ok, log_lines, log_truncated?}`.
    @MainActor
    func v2SupermuxChangesStashPop(params: [String: Any]) async -> V2CallResult {
        await supermuxChangesSyncMutation(params: params) { directory, service in
            try await service.popStash(repoPath: directory)
        }
    }

    /// `mobile.supermux.changes.history`: one page of the repository's commit
    /// history with `{limit?, cursor?}`. Result: `{commits, incoming,
    /// next_cursor?}` — `commits` carries `is_pushed` flags, `incoming` (the
    /// pullable `HEAD..@{upstream}` commits, first page only) rides along so
    /// the phone renders the desktop's Incoming section without a second
    /// call, and `next_cursor` (the page's last sha) resumes after this page
    /// when more history exists.
    @MainActor
    func v2SupermuxChangesHistory(params: [String: Any]) async -> V2CallResult {
        let target: (workspaceId: String, directory: String)
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return error
        case let .success(resolved): target = resolved
        }
        var limit = Self.supermuxHistoryDefaultLimit
        if let rawLimit = params["limit"] {
            guard let value = rawLimit as? Int, value > 0 else {
                return .err(
                    code: "invalid_params", message: "limit must be a positive integer", data: nil
                )
            }
            limit = min(value, Self.supermuxHistoryMaxLimit)
        }
        // Compound cursor `"<root-sha>.<offset>"`: the sha the WHOLE traversal
        // is pinned to (the first page's HEAD) and how many commits precede
        // this page. Paging by (pinned root, offset) rather than re-rooting at
        // the previous page's last sha is what keeps side-branch commits from
        // being silently dropped after page 1 (see `historyCommits`).
        let hasCursor = params["cursor"] != nil
        var root: String?
        var skip = 0
        if let rawCursor = params["cursor"] {
            guard let value = (rawCursor as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return .err(
                    code: "invalid_params", message: "cursor must be a history cursor", data: nil
                )
            }
            // The sha half is spliced into `git log`'s argv, so it MUST be a
            // bare hex object name and nothing else — otherwise a value like
            // `--output=/path` would be parsed by git as an option and could
            // overwrite an arbitrary user-writable file. The offset half must
            // be a non-negative integer. `next_cursor` always has this shape.
            let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  Self.supermuxIsFullCommitSha(String(parts[0])),
                  let offset = Int(parts[1]), offset >= 0 else {
                return .err(
                    code: "invalid_params", message: "cursor must be a history cursor", data: nil
                )
            }
            root = String(parts[0])
            skip = offset
        }
        let service = Self.supermuxMobileChangesService
        // First page only: refresh remote-tracking refs BEFORE anything reads
        // them. `status` (behind count), `unpushedCommits` (`is_pushed` flags),
        // and `incomingCommits` (`HEAD..@{upstream}`) are all only as fresh as
        // the last `git fetch`. Fetching after them would leave a commit that
        // was pushed from another clone flagged `is_pushed: false` and the
        // behind count stale until the next call. Best-effort: an offline/failed
        // fetch still returns the local history unchanged.
        if !hasCursor {
            _ = await service.fetch(repoPath: target.directory)
        }
        let snapshot = await service.status(repoPath: target.directory)
        let localCommits: [SupermuxGitCommit]
        if let page = await service.historyCommits(
            repoPath: target.directory, limit: limit + 1, from: root, skip: skip
        ) {
            localCommits = page
        } else if hasCursor {
            // The pinned root no longer names a commit (rebased away, or garbage).
            return .err(code: "not_found", message: "Unknown history cursor", data: nil)
        } else {
            // Unborn branch or not a repository: an empty history, not an error.
            localCommits = []
        }
        let unpushed = localCommits.isEmpty ? [] : await service.unpushedCommits(
            repoPath: target.directory,
            hasUpstream: snapshot.upstreamBranch != nil,
            limit: Self.supermuxHistoryUnpushedProbeLimit
        )
        let incoming: [SupermuxGitCommit] = hasCursor
            ? []
            : await service.incomingCommits(repoPath: target.directory, limit: limit)
        // Pin every later page to this traversal's root: the caller's `root`
        // once set, else the first page's HEAD (`localCommits.first`).
        let startSha = root ?? localCommits.first?.hash
        let nextCursor = startSha.map { "\($0).\(skip + limit)" } ?? ""
        do {
            return .ok(try SupermuxMobileChangesPayloadBuilder().history(
                localCommits: localCommits,
                limit: limit,
                unpushedShas: Set(unpushed.map(\.hash)),
                incoming: incoming,
                nextCursor: nextCursor
            ))
        } catch {
            return .err(code: "unavailable", message: "Failed to encode history", data: nil)
        }
    }

    /// Whether `value` is a full git commit object name (40 ASCII hex chars for
    /// sha-1, or 64 for sha-256) and therefore safe to splice into `git log`'s
    /// argv as a revision. ASCII-only on purpose: `Character.isHexDigit` accepts
    /// full-width Unicode digits (e.g. `０`/`Ｆ`), which git would reject anyway,
    /// but the wire contract for a cursor is a bare ASCII object name.
    private static func supermuxIsFullCommitSha(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39)  // 0-9
                    || (byte >= 0x61 && byte <= 0x66)  // a-f
                    || (byte >= 0x41 && byte <= 0x46)  // A-F
            }
    }

    // MARK: - Shared pieces

    /// Runs one sync mutation (push/pull/stash/stash_pop): resolves the
    /// workspace, executes `work` on the shared service, and encodes the
    /// invocation's captured git output as the `{ok, log_lines}` result. Git
    /// failures map to the shared `unavailable` error shape (mirroring
    /// `supermuxChangesMutation` in `SupermuxMobileHost+Changes.swift`).
    @MainActor
    private func supermuxChangesSyncMutation(
        params: [String: Any],
        work: @MainActor (String, SupermuxGitChangesService) async throws -> CommandResult
    ) async -> V2CallResult {
        let target: (workspaceId: String, directory: String)
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return error
        case let .success(resolved): target = resolved
        }
        do {
            let result = try await work(target.directory, Self.supermuxMobileChangesService)
            return .ok(SupermuxMobileChangesPayloadBuilder().sync(
                log: SupermuxMobileSyncLog.capture(result)
            ))
        } catch {
            return .err(code: "unavailable", message: error.localizedDescription, data: nil)
        }
    }
}

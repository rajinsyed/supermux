import Foundation

/// The Unpushed/Incoming commit-log queries for ``SupermuxGitChangesService``.
///
/// Split out of `SupermuxGitChangesService.swift` to keep the service file
/// inside the fork's Swift file-length budget.
extension SupermuxGitChangesService {
    /// Reads up to `limit` unpushed local commits (newest first): commits in
    /// `HEAD` that are not yet on the remote.
    ///
    /// With an upstream configured, the range is `@{upstream}..HEAD` (exactly
    /// the commits the branch is "ahead" by). Without one — a never-pushed or
    /// detached branch — it falls back to `HEAD --not --remotes`, i.e. commits
    /// reachable from `HEAD` that are not on any remote-tracking branch (in a
    /// repository with no remotes at all, that is the whole local history,
    /// which is correct: nothing has been pushed).
    ///
    /// Runs `git log -z --no-color --no-show-signature` with
    /// ``SupermuxGitCommit/logFormat``; `--no-show-signature` keeps GPG
    /// verification lines out of the stream for users with
    /// `log.showSignature=true`. Returns an empty array when git fails —
    /// including an empty repository / unborn branch or a missing upstream
    /// ref — so a missing list degrades quietly rather than as an error.
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - hasUpstream: Whether the current branch has an upstream configured.
    ///   - limit: Maximum number of commits to return.
    /// - Returns: The parsed unpushed commits, newest first, or `[]` on failure.
    public func unpushedCommits(
        repoPath: String, hasUpstream: Bool, limit: Int
    ) async -> [SupermuxGitCommit] {
        guard limit > 0 else { return [] }
        if hasUpstream,
           let upstreamCommits = await commitLog(
               repoPath: repoPath, revision: ["@{upstream}..HEAD"], limit: limit
           ) {
            return upstreamCommits
        }
        // No upstream, or the `@{upstream}` range failed (e.g. the
        // remote-tracking ref is missing locally): fall back to "not on any
        // remote" rather than misleadingly claiming nothing is unpushed.
        return await commitLog(
            repoPath: repoPath, revision: ["HEAD", "--not", "--remotes"], limit: limit
        ) ?? []
    }

    /// Counts unpushed commits for a branch with no upstream:
    /// `git rev-list --count HEAD --not --remotes` — commits reachable from
    /// `HEAD` but not on any remote-tracking branch (the same set
    /// ``unpushedCommits(repoPath:hasUpstream:limit:)`` falls back to).
    ///
    /// Used only when `git status` reports no `ahead` count to drive the panel's
    /// "hide the Unpushed section when empty" decision without loading the whole
    /// list. Returns `0` on failure (e.g. an unborn branch) or an empty range.
    /// - Parameter repoPath: Repository directory.
    public func unpushedCountWithoutUpstream(repoPath: String) async -> Int {
        let stdout = await runner.runStandardOutput(
            directory: repoPath,
            executable: "git",
            arguments: [Self.noOptionalLocks, "rev-list", "--count", "HEAD", "--not", "--remotes"],
            timeout: Self.gitTimeout
        )
        return stdout.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    /// Reads up to `limit` incoming commits (newest first): commits on the
    /// upstream that are not yet in `HEAD` — exactly what `git pull` would bring.
    ///
    /// The range is `HEAD..@{upstream}`. The remote-tracking ref is only as
    /// fresh as the last `git fetch`, so callers run ``fetch(repoPath:)`` first
    /// to surface commits pushed elsewhere (e.g. a merged worktree). Unlike
    /// ``unpushedCommits(repoPath:hasUpstream:limit:)`` there is no
    /// remotes-based fallback: with no upstream there is nothing to pull, so an
    /// empty array is returned. Also `[]` when the range is empty or git fails
    /// (for example a detached HEAD without `@{upstream}`).
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - limit: Maximum number of commits to return.
    /// - Returns: The parsed incoming commits, newest first, or `[]`.
    public func incomingCommits(repoPath: String, limit: Int) async -> [SupermuxGitCommit] {
        guard limit > 0 else { return [] }
        return await commitLog(
            repoPath: repoPath, revision: ["HEAD..@{upstream}"], limit: limit
        ) ?? []
    }

    /// Runs `git log` over `revision` and parses the result; `nil` on git
    /// failure (so callers can fall back) versus `[]` for a successful empty
    /// range.
    private func commitLog(
        repoPath: String, revision: [String], limit: Int
    ) async -> [SupermuxGitCommit]? {
        let result = await runner.run(
            directory: repoPath,
            executable: "git",
            arguments: [
                Self.noOptionalLocks, "log", "-z", "--no-color", "--no-show-signature",
                "--max-count=\(limit)", "--format=\(SupermuxGitCommit.logFormat)",
            ] + revision,
            timeout: Self.gitTimeout
        )
        guard result.exitStatus == 0, let stdout = result.stdout else { return nil }
        return SupermuxGitCommit.parse(log: stdout)
    }
}

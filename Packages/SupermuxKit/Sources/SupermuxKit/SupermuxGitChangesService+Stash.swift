public import CmuxFoundation
import Foundation

/// Stash operations for ``SupermuxGitChangesService``.
///
/// Split out of `SupermuxGitChangesService.swift` to keep the service file
/// inside the fork's Swift file-length budget.
extension SupermuxGitChangesService {
    /// Stashes working-tree changes (`git stash push`).
    ///
    /// By default only tracked-file changes (staged or unstaged) are stashed;
    /// pass `includeUntracked` to add `--include-untracked` so untracked files
    /// are stashed too. `git stash push` exits `0` with "No local changes to
    /// save" when there is nothing to stash, so this never throws on a clean
    /// tree — callers gate the action on having changes.
    /// - Parameters:
    ///   - repoPath: Repository directory.
    ///   - includeUntracked: Whether to also stash untracked files.
    ///   - message: Optional stash message (`-m`); blank/`nil` keeps git's
    ///     default "WIP on <branch>" entry name.
    /// - Returns: git's captured output (stdout/stderr), for callers that
    ///   surface a log (the mobile `changes.stash` `log_lines`).
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    @discardableResult
    public func stash(
        repoPath: String, includeUntracked: Bool, message: String? = nil
    ) async throws -> CommandResult {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if let message, !message.isEmpty { arguments += ["-m", message] }
        return try await runGit(
            in: repoPath, arguments,
            commandLabel: includeUntracked ? "stash push --include-untracked" : "stash push"
        )
    }

    /// Restores the most recent stash and drops it (`git stash pop`).
    ///
    /// A `pop` that produces merge conflicts exits non-zero and leaves the
    /// stash in place with conflict markers in the working tree; that surfaces
    /// as a ``SupermuxGitError/gitFailed(command:message:)`` for the caller to
    /// show, while the conflicted files appear on the next status refresh.
    /// - Parameter repoPath: Repository directory.
    /// - Returns: git's captured output (stdout/stderr), for callers that
    ///   surface a log (the mobile `changes.stash_pop` `log_lines`).
    /// - Throws: ``SupermuxGitError/gitFailed(command:message:)`` when git errors.
    @discardableResult
    public func popStash(repoPath: String) async throws -> CommandResult {
        try await runGit(in: repoPath, ["stash", "pop"], commandLabel: "stash pop")
    }
}

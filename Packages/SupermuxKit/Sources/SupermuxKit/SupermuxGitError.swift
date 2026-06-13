public import Foundation

/// Errors thrown by ``SupermuxGitWorktreeService``.
public enum SupermuxGitError: Error, LocalizedError, Equatable, Sendable {
    /// The project root is not a git repository.
    case notAGitRepository(path: String)
    /// User input could not be turned into a valid branch name.
    case invalidBranchName(input: String)
    /// The computed worktree path escaped the worktrees directory.
    case unsafeWorktreePath(path: String)
    /// The worktree has uncommitted changes; pass `force` to override.
    case dirtyWorktree(path: String)
    /// Deleting a worktree supermux does not manage was refused.
    case unmanagedWorktree(path: String)
    /// The base branch could not be resolved locally or on `origin`.
    case unknownBaseBranch(name: String)
    /// A git command failed; carries the command and stderr for display.
    case gitFailed(command: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notAGitRepository(let path):
            return String(
                localized: "supermux.gitError.notARepo",
                defaultValue: "\(path) is not a git repository."
            )
        case .invalidBranchName(let input):
            return String(
                localized: "supermux.gitError.invalidBranch",
                defaultValue: "“\(input)” cannot be turned into a valid branch name."
            )
        case .unsafeWorktreePath(let path):
            return String(
                localized: "supermux.gitError.unsafePath",
                defaultValue: "Refusing to use worktree path outside the project: \(path)"
            )
        case .dirtyWorktree(let path):
            return String(
                localized: "supermux.gitError.dirtyWorktree",
                defaultValue: "The worktree at \(path) has uncommitted changes."
            )
        case .unmanagedWorktree(let path):
            return String(
                localized: "supermux.gitError.unmanagedWorktree",
                defaultValue: "The worktree at \(path) was not created by supermux; remove it with git directly."
            )
        case .unknownBaseBranch(let name):
            return String(
                localized: "supermux.gitError.unknownBase",
                defaultValue: "Base branch “\(name)” was not found locally or on origin."
            )
        case .gitFailed(let command, let message):
            return String(
                localized: "supermux.gitError.gitFailed",
                defaultValue: "git \(command) failed: \(message)"
            )
        }
    }
}

public import Foundation

/// Maps ``SupermuxGitError`` onto the reserved mobile RPC error codes
/// (architecture §3), so the `mobile.supermux.worktree.*` handlers surface
/// the exact wire codes the contract names — most importantly
/// `dirty_worktree` for a removal blocked by uncommitted changes.
public enum SupermuxMobileWorktreeErrorCode {
    /// The wire error code for a worktree-service failure.
    ///
    /// - `dirtyWorktree` → `dirty_worktree` (retry with `force: true`).
    /// - `unmanagedWorktree` → `forbidden` (supermux refuses to delete
    ///   worktrees it does not manage).
    /// - Caller-precondition failures (bad branch input, unknown base, a
    ///   project root that is not a git repository) → `invalid_params`.
    /// - Everything else (git itself failed, unsafe computed path) →
    ///   `unavailable`.
    /// - Parameter error: The thrown git-service error.
    /// - Returns: One of the reserved wire codes.
    public static func wireCode(for error: SupermuxGitError) -> String {
        switch error {
        case .dirtyWorktree:
            return "dirty_worktree"
        case .unmanagedWorktree:
            return "forbidden"
        case .invalidBranchName, .unknownBaseBranch, .notAGitRepository:
            return "invalid_params"
        case .unsafeWorktreePath, .gitFailed:
            return "unavailable"
        }
    }
}

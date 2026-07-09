import CmuxMobileRPC

/// Extracts the Mac's `code` field from a thrown RPC error.
///
/// The transport surfaces server-reported errors as
/// `MobileShellConnectionError.rpcError(code, message)`; stores branch on the
/// reserved codes (architecture §3) — e.g. `dirty_worktree` drives the
/// confirm-force removal flow. Fakes throw the same error type so tests
/// exercise the exact production decode path.
/// lint:allow namespace-type — wire-constant namespace for the architecture §3 reserved error codes plus a pure extractor; stateless and dependency-free, nothing to instantiate.
public enum SupermuxWireErrorCode {
    /// `worktree.remove` without `force` on a worktree with uncommitted
    /// changes.
    public static let dirtyWorktree = "dirty_worktree"

    /// AI-backed methods (`changes.generate_commit_message`,
    /// `worktree.suggest_branch`) when no AI key is configured OR generation
    /// failed — the two cases carry distinct messages worth surfacing.
    public static let aiUnavailable = "ai_unavailable"

    /// The server-reported error code carried by `error`, or `nil` when the
    /// error is not an RPC error (or carried no code).
    /// - Parameter error: The error a seam call threw.
    public static func code(from error: any Error) -> String? {
        guard let connectionError = error as? MobileShellConnectionError,
              case let .rpcError(code, _) = connectionError else {
            return nil
        }
        return code
    }

    /// The server-reported error message carried by `error`, or `nil` when
    /// the error is not an RPC error.
    /// - Parameter error: The error a seam call threw.
    public static func message(from error: any Error) -> String? {
        guard let connectionError = error as? MobileShellConnectionError,
              case let .rpcError(_, message) = connectionError else {
            return nil
        }
        return message
    }
}

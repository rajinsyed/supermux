import CmuxMobileRPC

/// Extracts the Mac's `code` field from a thrown RPC error.
///
/// The transport surfaces server-reported errors as
/// `MobileShellConnectionError.rpcError(code, message)`; stores branch on the
/// reserved codes (architecture §3) — e.g. `dirty_worktree` drives the
/// confirm-force removal flow. Fakes throw the same error type so tests
/// exercise the exact production decode path.
public enum SupermuxWireErrorCode {
    /// `worktree.remove` without `force` on a worktree with uncommitted
    /// changes.
    public static let dirtyWorktree = "dirty_worktree"

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
}

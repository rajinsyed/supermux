/// The worktree RPC budget shared by iPhone and Mac callers.
///
/// Covers the host's base fetch (30 s), checkout (600 s), submodules (600 s),
/// teardown (120 s), and three local git/AI operations (30 s each).
/// `SupermuxDeviceReplyDeadlineTests` checks this against the host's bounds.
/// lint:allow namespace-type — shared wire-contract constants, with no instance state.
public enum SupermuxWorktreeReplyDeadline {
    /// Reply budget in seconds, including margin for naming and workspace open.
    public static let seconds = 24 * 60

    /// The same budget in the iPhone RPC client's units.
    public static let rpcTimeoutNanoseconds = UInt64(seconds) * 1_000_000_000
}

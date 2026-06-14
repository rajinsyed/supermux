import Foundation

/// The environment variables supermux exports into a worktree's setup and
/// teardown scripts.
///
/// Setup/teardown scripts run with the *new worktree* as their working
/// directory but frequently need to reach back into the *main* project checkout
/// — most commonly to copy an untracked secret into the fresh worktree, e.g.:
///
/// ```sh
/// bun install
/// cp "$SUPERSET_ROOT_PATH/.env" .env
/// ```
///
/// `SUPERSET_ROOT_PATH` is kept for drop-in compatibility with superset /
/// piggycode `config.json` scripts (whose snippets reference it verbatim);
/// `SUPERMUX_ROOT_PATH` is the fork-native alias and carries the same value.
/// `SUPERMUX_WORKTREE_PATH` is the new worktree's absolute path (the script's
/// own working directory), provided so scripts don't have to recompute it.
public enum SupermuxWorktreeEnvironment {
    /// Builds the export environment for a worktree's setup/teardown script.
    /// - Parameters:
    ///   - projectRoot: The main project checkout the worktree was created from.
    ///   - worktreePath: The newly created worktree directory.
    /// - Returns: Variable name → value pairs to export for the script.
    public static func variables(projectRoot: String, worktreePath: String) -> [String: String] {
        let root = (projectRoot as NSString).expandingTildeInPath
        let worktree = (worktreePath as NSString).expandingTildeInPath
        return [
            "SUPERSET_ROOT_PATH": root,
            "SUPERMUX_ROOT_PATH": root,
            "SUPERMUX_WORKTREE_PATH": worktree,
        ]
    }
}

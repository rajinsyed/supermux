import Foundation
import Testing
@testable import SupermuxKit

/// Tests for the worktree setup/teardown script builders and the environment
/// variable contract exported into those scripts.
struct SupermuxWorktreeScriptTests {
    // MARK: - joined

    @Test func joinedTrimsDropsEmptiesAndPreservesInnerNewlines() {
        let script = SupermuxWorktreeScript.joined([
            "  bun install  ",
            "",
            "cp \"$SUPERSET_ROOT_PATH/.env\" .env\nexit",
        ])
        #expect(script == "bun install\ncp \"$SUPERSET_ROOT_PATH/.env\" .env\nexit")
    }

    @Test func joinedReturnsNilWhenNothingExecutable() {
        #expect(SupermuxWorktreeScript.joined([]) == nil)
        #expect(SupermuxWorktreeScript.joined(["", "   ", "\n"]) == nil)
    }

    // MARK: - envAssignments

    @Test func envAssignmentsAreSortedKeyValueTokens() {
        let assignments = SupermuxWorktreeScript.envAssignments([
            "B": "2",
            "A": "1 with space",
        ])
        // Sorted by key; value passed verbatim (no quoting — env handles it).
        #expect(assignments == ["A=1 with space", "B=2"])
    }

    // MARK: - environment contract

    @Test func environmentExportsBothRootAliasesAndWorktreePath() {
        let env = SupermuxWorktreeEnvironment.variables(
            projectRoot: "/repos/app",
            worktreePath: "/repos/app/.worktrees/feature"
        )
        #expect(env["SUPERSET_ROOT_PATH"] == "/repos/app")
        #expect(env["SUPERMUX_ROOT_PATH"] == "/repos/app")
        #expect(env["SUPERMUX_WORKTREE_PATH"] == "/repos/app/.worktrees/feature")
    }

    @Test func environmentExpandsTildePaths() {
        let env = SupermuxWorktreeEnvironment.variables(projectRoot: "~/app", worktreePath: "~/app/.worktrees/x")
        let home = NSHomeDirectory()
        #expect(env["SUPERSET_ROOT_PATH"] == home + "/app")
        #expect(env["SUPERMUX_WORKTREE_PATH"] == home + "/app/.worktrees/x")
    }
}

import SupermuxKit
import Testing

/// Tests for ``SupermuxCommandLaunch`` — the shared rule for how supermux turns
/// a user-configured command into terminal input and picks where it runs.
///
/// The working-directory cases are the regression guard for the bug where a
/// project app action ran in the project's fixed root checkout instead of the
/// focused workspace's directory (e.g. a git worktree): the rule must prefer the
/// focused workspace's directory and only fall back to the project root when the
/// workspace has no resolved directory yet.
struct SupermuxCommandLaunchTests {
    @Test func shellInputAppendsNewline() {
        #expect(SupermuxCommandLaunch.shellInput(for: "npm run dev") == "npm run dev\n")
    }

    @Test func prefersFocusedWorkspaceDirectoryOverProjectRoot() {
        // The repro: focused on a worktree, action carries the project root as
        // its fallback. The worktree must win.
        let directory = SupermuxCommandLaunch.workingDirectory(
            focusedWorkspaceDirectory: "/repo/.worktrees/feature",
            fallback: "/repo"
        )
        #expect(directory == "/repo/.worktrees/feature")
    }

    @Test func fallsBackWhenFocusedDirectoryIsEmpty() {
        let directory = SupermuxCommandLaunch.workingDirectory(
            focusedWorkspaceDirectory: "",
            fallback: "/repo"
        )
        #expect(directory == "/repo")
    }

    @Test func fallsBackWhenFocusedDirectoryIsWhitespace() {
        let directory = SupermuxCommandLaunch.workingDirectory(
            focusedWorkspaceDirectory: "   \n",
            fallback: "/repo"
        )
        #expect(directory == "/repo")
    }

    @Test func preservesNonBlankFocusedDirectoryVerbatim() {
        // A non-blank directory is returned exactly as given: surrounding spaces
        // are part of a legal POSIX path and must not be silently trimmed away
        // (the trim is only used to decide whether the directory is blank).
        let directory = SupermuxCommandLaunch.workingDirectory(
            focusedWorkspaceDirectory: "  /repo/.worktrees/feature  ",
            fallback: "/repo"
        )
        #expect(directory == "  /repo/.worktrees/feature  ")
    }
}

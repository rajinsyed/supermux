import Foundation

/// Shared rule for how supermux launches a user-configured command (terminal
/// preset, project app-action, or the ⌘G run command) in a workspace terminal.
///
/// Supermux runs these commands as interactive-shell **input**
/// (`initialInput` / `initialTerminalInput`, or `sendText` + Return for an
/// existing surface) rather than as the surface's exec command
/// (`initialCommand`). This is the one shared decision behind every command
/// entrypoint; keep all of them routed through ``shellInput(for:)`` so they
/// stay consistent.
///
/// Why input instead of `initialCommand`:
///   1. **Aliases and functions resolve.** The command runs inside the user's
///      interactive login shell, so `~/.zshrc` definitions apply — e.g. a
///      `cc` alias for `claude …`. An `initialCommand` is exec'd directly and
///      never sources the shell rc, so an alias falls through to an unrelated
///      binary (`cc` → the C compiler) that exits immediately.
///   2. **The terminal survives the command.** cmux closes a surface the moment
///      its child process exits (and collapses the workspace when it was the
///      last surface). Running the command as input keeps the interactive shell
///      as the child, so a one-shot or failed command returns to the prompt and
///      shows its output instead of the tab/workspace vanishing.
public enum SupermuxCommandLaunch {
    /// Builds the terminal input that runs `command` as if the user typed it
    /// into the workspace's interactive shell and pressed Return.
    ///
    /// The trailing newline submits the command. Delivered through
    /// `initialInput` it is a raw PTY write at startup, so it executes rather
    /// than being swallowed by bracketed paste.
    /// - Parameter command: The shell command to run.
    /// - Returns: The command followed by a newline.
    public static func shellInput(for command: String) -> String {
        command + "\n"
    }

    /// Chooses the working directory a project action runs in.
    ///
    /// Supermux runs these commands "where the user is looking": in the focused
    /// workspace's directory (e.g. a git worktree checkout), the same as the ⌘G
    /// run toggle and the presets bar — not a fixed project root. Falls back to
    /// `fallback` only when the focused workspace has no resolved directory yet
    /// (blank/whitespace), so a just-opened workspace still lands somewhere
    /// sensible.
    /// - Parameters:
    ///   - focusedWorkspaceDirectory: The focused workspace's working directory.
    ///   - fallback: Directory to use when the focused one is blank.
    /// - Returns: The directory the command should run in.
    public static func workingDirectory(
        focusedWorkspaceDirectory: String,
        fallback: String
    ) -> String {
        let trimmed = focusedWorkspaceDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

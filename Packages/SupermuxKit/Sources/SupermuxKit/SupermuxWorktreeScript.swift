import Foundation

/// Builds the shell input/commands for a worktree's setup and teardown scripts.
///
/// A project's setup/teardown is an ordered list of shell snippets (each entry
/// may itself span multiple lines — that is how `config.json` ships a whole
/// script in one string). This type is the single place that decides how those
/// snippets are normalized and combined, so the terminal (setup) and headless
/// (teardown) paths stay consistent and the rules are unit-testable without a
/// shell.
public enum SupermuxWorktreeScript {
    /// Joins setup/teardown snippets into a single newline-separated script.
    ///
    /// Blank entries are dropped and surrounding whitespace trimmed. Returns
    /// `nil` when nothing executable remains, so callers can skip the work
    /// entirely (no terminal spawned, no shell invoked).
    /// - Parameter commands: The ordered snippets from the project.
    /// - Returns: The combined script, or `nil` when empty.
    public static func joined(_ commands: [String]) -> String? {
        let cleaned = commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.joined(separator: "\n")
    }

    /// Renders `environment` as `KEY=VALUE` tokens for `/usr/bin/env`.
    ///
    /// The headless teardown path runs the script as
    /// `env KEY=VALUE … <shell> -lc <script>`: passing the variables as `env`
    /// arguments hands them to the kernel verbatim, so values with spaces or
    /// shell metacharacters need no quoting at all (no shell parses them).
    /// Sorted for a deterministic, testable argument list.
    /// - Parameter environment: Variable name → value pairs.
    /// - Returns: `["KEY=VALUE", …]` in sorted key order.
    public static func envAssignments(_ environment: [String: String]) -> [String] {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

import Foundation

/// Builds the one shell line that starts Claude in a fresh worktree terminal.
///
/// The line is submitted as interactive-shell *input* (see
/// ``SupermuxCommandLaunch``) so the user's command may be an alias or a
/// function; the prompt travels as Claude's positional argument so the
/// session opens with it already sent.
public enum SupermuxAgentLaunchCommand {
    /// Composes `<command> [--model M] [--effort E] '<prompt>'`.
    ///
    /// The prompt is quoted with ANSI-C `$'…'` quoting, which both zsh and
    /// bash accept: it keeps a multi-line prompt on ONE input line (embedded
    /// newlines become `\n`), so the terminal's bracketed-paste path submits a
    /// single command instead of splitting the prompt across prompts.
    ///
    /// - Parameters:
    ///   - command: The user's Claude command (`claude`, `cc`, `ccx`, …).
    ///   - model: A `--model` selector, or `nil` for the CLI default.
    ///   - effort: An `--effort` level, or `nil` for the CLI default.
    ///   - prompt: The task Claude should start on.
    /// - Returns: The shell line to run, without a trailing newline.
    public static func shellLine(
        command: String,
        model: String?,
        effort: String?,
        prompt: String
    ) -> String {
        var parts = [command.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let model = normalized(model) {
            parts.append("--model")
            parts.append(SupermuxShellQuoting.singleQuoted(model))
        }
        if let effort = normalized(effort) {
            parts.append("--effort")
            parts.append(SupermuxShellQuoting.singleQuoted(effort))
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            parts.append(SupermuxShellQuoting.ansiCQuoted(trimmedPrompt))
        }
        return parts.joined(separator: " ")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// POSIX-shell quoting helpers shared by the agent launch paths.
public enum SupermuxShellQuoting {
    /// Wraps `value` in single quotes, escaping embedded single quotes the
    /// portable way (`'\''`). Safe for any byte sequence except newlines,
    /// which stay literal — use ``ansiCQuoted(_:)`` for multi-line text.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wraps `value` in `$'…'` (ANSI-C quoting, zsh + bash), escaping
    /// backslashes and single quotes and turning newlines, carriage returns,
    /// and tabs into their escape sequences so the result is one line.
    public static func ansiCQuoted(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 8)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "'": escaped += "\\'"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "$'" + escaped + "'"
    }
}

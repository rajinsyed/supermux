import Foundation

/// The quoting dialect of the shell that will read a launch line.
///
/// The line is typed into the new workspace's interactive shell, so it has
/// to be quoted for THAT shell. bash and zsh (and macOS's `/bin/sh`, which is
/// bash) share ANSI-C `$'…'` quoting; fish has its own escape rules.
public enum SupermuxShellFlavor: Equatable, Sendable {
    /// bash, zsh, ksh, sh: ANSI-C quoting is available.
    case posix
    /// fish: single quotes with `\'` / `\\` escapes, `\n` only unquoted.
    case fish

    /// Detects the flavor from a shell path (`$SHELL`); unknown shells are
    /// treated as POSIX.
    /// - Parameter shellPath: The shell executable path.
    public static func detect(shellPath: String) -> SupermuxShellFlavor {
        URL(fileURLWithPath: shellPath).lastPathComponent == "fish" ? .fish : .posix
    }
}

/// Builds the one shell line that starts Claude in a fresh worktree terminal.
///
/// The line is submitted as interactive-shell *input* (see
/// ``SupermuxCommandLaunch``) so the user's command may be an alias or a
/// function; the prompt travels as Claude's positional argument so the
/// session opens with it already sent.
public enum SupermuxAgentLaunchCommand {
    /// Composes `<command> [--model M] [--effort E] -- '<prompt>'`.
    ///
    /// The `--` terminator keeps a prompt that happens to start with `-` from
    /// being parsed as an option. The prompt is quoted for `shell` so a
    /// multi-line prompt stays on ONE input line (embedded newlines become
    /// `\n` escapes), so the terminal's bracketed-paste path submits a single
    /// command instead of splitting the prompt across prompts.
    ///
    /// - Parameters:
    ///   - command: The user's Claude command (`claude`, `cc`, `ccx`, …).
    ///   - model: A `--model` selector, or `nil` for the CLI default.
    ///   - effort: An `--effort` level, or `nil` for the CLI default.
    ///   - prompt: The task Claude should start on.
    ///   - shell: The dialect of the shell that will read the line.
    /// - Returns: The shell line to run, without a trailing newline.
    public static func shellLine(
        command: String,
        model: String?,
        effort: String?,
        prompt: String,
        shell: SupermuxShellFlavor = .posix
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
            parts.append("--")
            parts.append(SupermuxShellQuoting.oneLineQuoted(trimmedPrompt, for: shell))
        }
        return parts.joined(separator: " ")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Shell quoting helpers shared by the agent launch paths.
public enum SupermuxShellQuoting {
    /// Wraps `value` in single quotes, escaping embedded single quotes the
    /// portable way (`'\''`). Safe for any byte sequence except newlines,
    /// which stay literal — use ``oneLineQuoted(_:for:)`` for multi-line text.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes `value` as ONE input line for `shell`: ``ansiCQuoted(_:)`` for
    /// POSIX shells, ``fishQuoted(_:)`` for fish.
    public static func oneLineQuoted(_ value: String, for shell: SupermuxShellFlavor) -> String {
        switch shell {
        case .posix: return ansiCQuoted(value)
        case .fish: return fishQuoted(value)
        }
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

    /// Quotes `value` for fish on one line. Inside fish single quotes only
    /// `\'` and `\\` are escapes, so line breaks and tabs are emitted
    /// UNQUOTED (`\n`, `\r`, `\t`) between quoted runs — adjacent words
    /// concatenate into a single argument.
    public static func fishQuoted(_ value: String) -> String {
        var quoted = "'"
        quoted.reserveCapacity(value.count + 8)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "'": quoted += "\\'"
            case "\n": quoted += "'\\n'"
            case "\r": quoted += "'\\r'"
            case "\t": quoted += "'\\t'"
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "'"
    }
}

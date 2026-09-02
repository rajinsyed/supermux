public import Foundation

/// Builds the process plan that reads a Claude *command*'s model catalog.
///
/// The harness probe (``SupermuxHarnessModelCatalogProbe``) needs a real
/// executable to spawn, but the user's command may be a shell alias (`cc`)
/// or a function that only exists inside their interactive shell. So the
/// probe runs the command THROUGH that shell — `zsh -lic '<command> "$@"'` —
/// which sources the login profile (PATH) and the rc file (aliases), then
/// appends Claude's stream-json flags so the process answers `initialize`
/// and exits without ever starting a turn.
public enum SupermuxAgentCommandProbePlan {
    /// The Claude arguments that make a launch answer `initialize` over stdio.
    static let streamJSONArguments = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--permission-prompt-tool", "stdio",
    ]

    /// The shell to run commands through: `$SHELL` when set, else zsh.
    /// - Parameter environment: The process environment to read.
    public static func shellPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    /// The launch plan for probing `command`.
    ///
    /// - Parameters:
    ///   - command: The user's Claude command (alias, function, script, or binary).
    ///   - shellPath: The interactive shell to resolve it in.
    ///   - workingDirectoryURL: Where the process runs (a project root; some
    ///     wrappers read project settings).
    ///   - environment: The environment to inherit.
    /// - Returns: A plan the harness probe can spawn.
    public static func plan(
        command: String,
        shellPath: String,
        workingDirectoryURL: URL,
        environment: [String: String]
    ) -> SupermuxHarnessLaunchPlan {
        var launchEnvironment = environment
        launchEnvironment["PWD"] = workingDirectoryURL.standardizedFileURL.path
        return SupermuxHarnessLaunchPlan(
            executableURL: URL(fileURLWithPath: shellPath),
            arguments: shellArguments(command: command),
            environment: launchEnvironment,
            workingDirectoryURL: workingDirectoryURL.standardizedFileURL
        )
    }

    /// `-lic '<command> "$@"' <command> <stream-json flags…>`.
    ///
    /// With `-c`, the word after the script becomes `$0` and the rest `$@`, so
    /// the flags reach the command verbatim without a second round of shell
    /// parsing. The script body itself is the trimmed command text, so a
    /// command that is already a phrase (`claude --settings x`) still works.
    static func shellArguments(command: String) -> [String] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["-lic", trimmed + " \"$@\"", trimmed] + streamJSONArguments
    }
}

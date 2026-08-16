public import Foundation

/// A complete executable, argument, environment, and working-directory plan for one Claude process.
public struct SupermuxHarnessLaunchPlan: Equatable, Sendable {
    /// The resolved real Claude Code executable.
    public let executableURL: URL
    /// The required and optional Claude Code arguments.
    public let arguments: [String]
    /// The inherited environment with `PWD` set to the working directory.
    public let environment: [String: String]
    /// The process working directory.
    public let workingDirectoryURL: URL

    /// Builds a launch plan that always uses bidirectional stream-json and stdio permissions.
    ///
    /// `PATH` is preserved exactly as supplied. The app-side executable resolver is responsible for
    /// prepending the resolved executable directory when needed.
    ///
    /// - Parameters:
    ///   - executableURL: The executable selected by the app-side resolver.
    ///   - workingDirectoryURL: The directory in which Claude should operate.
    ///   - environment: The environment to inherit and pass through.
    ///   - options: Optional model, permission, resume, fork, effort, and replay controls.
    public init(
        executableURL: URL,
        workingDirectoryURL: URL,
        environment: [String: String],
        options: SupermuxHarnessLaunchOptions = SupermuxHarnessLaunchOptions()
    ) {
        let directory = workingDirectoryURL.standardizedFileURL
        var launchEnvironment = environment
        launchEnvironment["PWD"] = directory.path

        var launchArguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-prompt-tool", "stdio",
        ]
        if let model = options.model, !model.isEmpty {
            launchArguments.append(contentsOf: ["--model", model])
        }
        if let permissionMode = options.permissionMode {
            launchArguments.append(contentsOf: ["--permission-mode", permissionMode.rawValue])
        }
        if let sessionID = options.resumeSessionID, !sessionID.isEmpty {
            launchArguments.append(contentsOf: ["--resume", sessionID])
        }
        if options.forkSession {
            launchArguments.append("--fork-session")
        }
        if let effort = options.effort, !effort.isEmpty {
            launchArguments.append(contentsOf: ["--effort", effort])
        }
        if options.replayUserMessages {
            launchArguments.append("--replay-user-messages")
        }

        self.executableURL = executableURL.standardizedFileURL
        arguments = launchArguments
        self.environment = launchEnvironment
        self.workingDirectoryURL = directory
    }

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
    }
}

import Foundation

/// Builds the exact argument vector for one Claude Code spawn.
///
/// Base flags follow the plan ruling: stream-json both ways, partial messages,
/// verbose, replayed user messages. Permissions are always skipped —
/// `--dangerously-skip-permissions` is added for launchers that need it (ccx
/// injects its own) and no permission-prompt flag is ever passed. Thinking
/// budget and fast mode are applied after startup through controls.
public struct ClaudeSpawnArguments: Sendable, Equatable {
    /// How the session identifies itself to the provider.
    public enum SessionIdentity: Sendable, Equatable {
        /// Fresh session with a pre-generated provider UUID.
        case new(sessionID: String)
        /// Resume of a persisted provider session.
        case resume(sessionID: String)
    }

    public var identity: SessionIdentity
    public var model: String?
    public var effort: String?

    public init(identity: SessionIdentity, model: String? = nil, effort: String? = nil) {
        self.identity = identity
        self.model = model
        self.effort = effort
    }

    /// The complete argument list (excluding the executable itself).
    public func arguments(for launcher: ClaudeLauncher) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--replay-user-messages",
        ]
        if launcher.addsSkipPermissionsFlag {
            args.append("--dangerously-skip-permissions")
        }
        switch identity {
        case .new(let sessionID):
            args.append(contentsOf: ["--session-id", sessionID])
        case .resume(let sessionID):
            args.append(contentsOf: ["--resume", sessionID])
        }
        if let model {
            args.append(contentsOf: ["--model", model])
        }
        if let effort {
            args.append(contentsOf: ["--effort", effort])
        }
        return args
    }
}

public import Foundation
public import SupermuxClaudeHarness

/// Immutable configuration for one Claude harness session.
public struct ClaudeSessionConfiguration: Sendable {
    /// The stable local session identity (also the persistence key).
    public let id: UUID
    public let launcher: ClaudeLauncher
    public let workingDirectory: String
    /// Fresh provider UUID or persisted resume identity.
    public let identity: ClaudeSpawnArguments.SessionIdentity
    public let model: String?
    public let effort: String?
    /// Child environment; `nil` inherits the parent environment.
    public let environment: [String: String]?

    public init(
        id: UUID = UUID(),
        launcher: ClaudeLauncher,
        workingDirectory: String,
        identity: ClaudeSpawnArguments.SessionIdentity,
        model: String? = nil,
        effort: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.id = id
        self.launcher = launcher
        self.workingDirectory = workingDirectory
        self.identity = identity
        self.model = model
        self.effort = effort
        self.environment = environment
    }

    /// The exact spawn arguments for this configuration.
    public var spawnArguments: [String] {
        ClaudeSpawnArguments(identity: identity, model: model, effort: effort)
            .arguments(for: launcher)
    }
}

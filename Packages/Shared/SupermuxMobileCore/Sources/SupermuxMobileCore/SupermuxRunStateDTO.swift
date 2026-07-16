/// Wire representation of a project's run-action state (the ⌘G dev-server
/// start/stop feature).
public struct SupermuxRunStateDTO: Codable, Sendable, Equatable {
    /// The project this run state belongs to (UUID string).
    public var projectId: String
    /// Whether the run action is currently running.
    public var isRunning: Bool?
    /// The command the run action is executing, when running.
    public var command: String?
    /// The workspace hosting the run terminal, when running.
    public var workspaceId: String?
    /// When the run started, Unix seconds.
    public var startedAt: Double?

    /// Creates a run-state DTO.
    /// - Parameters:
    ///   - projectId: The owning project's id.
    ///   - isRunning: Optional running flag.
    ///   - command: Optional running command.
    ///   - workspaceId: Optional hosting workspace id.
    ///   - startedAt: Optional start time, Unix seconds.
    public init(
        projectId: String,
        isRunning: Bool? = nil,
        command: String? = nil,
        workspaceId: String? = nil,
        startedAt: Double? = nil
    ) {
        self.projectId = projectId
        self.isRunning = isRunning
        self.command = command
        self.workspaceId = workspaceId
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case isRunning = "is_running"
        case command
        case workspaceId = "workspace_id"
        case startedAt = "started_at"
    }
}

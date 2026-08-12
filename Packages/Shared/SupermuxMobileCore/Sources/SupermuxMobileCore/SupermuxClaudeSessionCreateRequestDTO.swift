/// Parameters for `mobile.supermux.claude.session.create`.
public struct SupermuxClaudeSessionCreateRequestDTO: Codable, Sendable, Equatable {
    /// Absolute working directory on the Mac.
    public var cwd: String
    /// Associated Supermux project, when any.
    public var projectID: String?
    /// Launcher selected for the session lifetime.
    public var launcher: SupermuxClaudeLauncher
    /// Initial model value, or `nil` for the launcher default.
    public var model: String?
    /// Initial effort value, or `nil` for the model default.
    public var effort: String?
    /// Whether to request fast mode.
    public var fastMode: Bool
    /// Initial thinking-token maximum, when configured.
    public var thinkingBudget: Int?
    /// Optional prompt to dispatch after startup.
    public var initialPrompt: String?

    /// Creates a session-creation request.
    /// - Parameters:
    ///   - cwd: Absolute working directory.
    ///   - projectID: Associated Supermux project.
    ///   - launcher: Launcher selected for the session lifetime.
    ///   - model: Initial model value.
    ///   - effort: Initial effort value.
    ///   - fastMode: Whether to request fast mode.
    ///   - thinkingBudget: Initial thinking-token maximum.
    ///   - initialPrompt: Optional prompt dispatched after startup.
    public init(
        cwd: String,
        projectID: String? = nil,
        launcher: SupermuxClaudeLauncher,
        model: String? = nil,
        effort: String? = nil,
        fastMode: Bool = false,
        thinkingBudget: Int? = nil,
        initialPrompt: String? = nil
    ) {
        self.cwd = cwd
        self.projectID = projectID
        self.launcher = launcher
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
        self.thinkingBudget = thinkingBudget
        self.initialPrompt = initialPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case projectID = "project_id"
        case launcher
        case model
        case effort
        case fastMode = "fast_mode"
        case thinkingBudget = "thinking_budget"
        case initialPrompt = "initial_prompt"
    }
}

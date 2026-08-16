/// Optional Claude Code launch controls layered onto the required stream-json arguments.
public struct SupermuxHarnessLaunchOptions: Equatable, Sendable {
    /// An account-supported model selector.
    public var model: String?
    /// The initial permission mode.
    public var permissionMode: SupermuxHarnessPermissionMode?
    /// A session identifier to resume.
    public var resumeSessionID: String?
    /// Whether a resumed session should fork to a new identifier.
    public var forkSession: Bool
    /// An account-supported effort level.
    public var effort: String?
    /// Whether Claude Code should replay user messages on resume.
    public var replayUserMessages: Bool

    /// Creates optional launch controls.
    ///
    /// - Parameters:
    ///   - model: Optional model selector.
    ///   - permissionMode: Optional initial permission mode.
    ///   - resumeSessionID: Optional session to resume.
    ///   - forkSession: Whether to fork the resumed session.
    ///   - effort: Optional effort level.
    ///   - replayUserMessages: Whether to replay user messages on resume.
    public init(
        model: String? = nil,
        permissionMode: SupermuxHarnessPermissionMode? = nil,
        resumeSessionID: String? = nil,
        forkSession: Bool = false,
        effort: String? = nil,
        replayUserMessages: Bool = false
    ) {
        self.model = model
        self.permissionMode = permissionMode
        self.resumeSessionID = resumeSessionID
        self.forkSession = forkSession
        self.effort = effort
        self.replayUserMessages = replayUserMessages
    }
}

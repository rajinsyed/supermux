/// System frame subtypes handled by the harness.
public enum SupermuxHarnessSystemSubtype: String, CaseIterable, Sendable {
    /// Initial session metadata and capabilities.
    case initialize = "init"
    /// Transient requesting or compacting status.
    case status
    /// Authoritative idle, running, or requires-action state.
    case sessionStateChanged = "session_state_changed"
    /// A conversation compaction divider.
    case compactBoundary = "compact_boundary"
    /// Live estimated thinking-token usage.
    case thinkingTokens = "thinking_tokens"
    /// An API retry notice.
    case apiRetry = "api_retry"
    /// A hook started.
    case hookStarted = "hook_started"
    /// Hook progress changed.
    case hookProgress = "hook_progress"
    /// A hook completed.
    case hookResponse = "hook_response"
    /// Informational content from Claude Code.
    case informational
    /// A general notification.
    case notification
    /// An automatically denied tool-use notice.
    case permissionDenied = "permission_denied"
    /// A background task started.
    case taskStarted = "task_started"
    /// Background task progress changed.
    case taskProgress = "task_progress"
    /// Background task metadata changed.
    case taskUpdated = "task_updated"
    /// A background task completed or notified.
    case taskNotification = "task_notification"
    /// The authoritative background-task set changed.
    case backgroundTasksChanged = "background_tasks_changed"
    /// A model refusal retracted prior messages.
    case modelRefusalFallback = "model_refusal_fallback"
    /// Output from a local slash command.
    case localCommandOutput = "local_command_output"
    /// The current conversation was cleared and reset.
    case conversationReset = "conversation_reset"
}

/// A recognized system frame.
public struct SupermuxHarnessSystemFrame: Sendable {
    /// The recognized system subtype.
    public let subtype: SupermuxHarnessSystemSubtype
    /// The session identifier when supplied by the CLI.
    public let sessionID: String?
    /// The frame UUID when supplied by the CLI.
    public let uuid: String?
    /// The complete raw frame.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a system frame.
    ///
    /// - Parameters:
    ///   - subtype: The recognized subtype.
    ///   - sessionID: The optional session identifier.
    ///   - uuid: The optional frame UUID.
    ///   - rawObject: The complete raw frame.
    public init(
        subtype: SupermuxHarnessSystemSubtype,
        sessionID: String?,
        uuid: String?,
        rawObject: SupermuxHarnessJSONObject
    ) {
        self.subtype = subtype
        self.sessionID = sessionID
        self.uuid = uuid
        self.rawObject = rawObject
    }
}

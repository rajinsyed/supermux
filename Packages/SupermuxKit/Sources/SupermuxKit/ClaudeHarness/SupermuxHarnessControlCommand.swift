/// A client-issued Claude Code control request.
public enum SupermuxHarnessControlCommand: Sendable, Equatable {
    /// Requests the account-specific command, agent, model, and capability catalog.
    case initialize
    /// Interrupts the active turn and optionally cancels queued messages.
    case interrupt(cancelQueued: Bool?)
    /// Changes the current permission mode.
    case setPermissionMode(SupermuxHarnessPermissionMode)
    /// Changes or resets the model and optionally sets effort.
    case setModel(model: String?, effort: String?)
    /// Changes or resets the legacy maximum-thinking-token setting.
    case setMaxThinkingTokens(Int?)
    /// Requests authoritative context-window usage.
    case getContextUsage
    /// Renames the persisted session.
    case renameSession(title: String)
    /// Cancels a queued user message by its stamped UUID.
    case cancelAsyncMessage(messageUUID: String)
    /// Requests CLI-side file suggestions for an at-mention query.
    case fileSuggestions(query: String)

    var subtype: String {
        switch self {
        case .initialize: "initialize"
        case .interrupt: "interrupt"
        case .setPermissionMode: "set_permission_mode"
        case .setModel: "set_model"
        case .setMaxThinkingTokens: "set_max_thinking_tokens"
        case .getContextUsage: "get_context_usage"
        case .renameSession: "rename_session"
        case .cancelAsyncMessage: "cancel_async_message"
        case .fileSuggestions: "file_suggestions"
        }
    }
}

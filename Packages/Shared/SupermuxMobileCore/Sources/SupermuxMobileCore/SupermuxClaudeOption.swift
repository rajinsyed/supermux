/// A mutable Claude harness session option.
public enum SupermuxClaudeOption: String, CaseIterable, Codable, Sendable, Equatable {
    /// Claude model value.
    case model
    /// Model effort level.
    case effort
    /// Fast-mode toggle.
    case fastMode = "fast_mode"
    /// Maximum thinking-token setting.
    case thinkingBudget = "thinking_budget"
}

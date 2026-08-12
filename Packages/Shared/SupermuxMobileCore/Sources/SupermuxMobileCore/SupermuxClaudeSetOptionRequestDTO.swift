/// Parameters for `mobile.supermux.claude.set_option`.
public struct SupermuxClaudeSetOptionRequestDTO: Codable, Sendable, Equatable {
    /// Session whose option should change.
    public var sessionID: String
    /// Option to mutate.
    public var option: SupermuxClaudeOption
    /// New scalar option value.
    public var value: SupermuxClaudeOptionValue

    /// Creates an option mutation request.
    /// - Parameters:
    ///   - sessionID: Stable harness session identifier.
    ///   - option: Option to mutate.
    ///   - value: New scalar value.
    public init(sessionID: String, option: SupermuxClaudeOption, value: SupermuxClaudeOptionValue) {
        self.sessionID = sessionID
        self.option = option
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case option
        case value
    }
}

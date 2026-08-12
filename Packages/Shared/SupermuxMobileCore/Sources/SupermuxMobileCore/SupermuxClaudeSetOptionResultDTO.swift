/// Reconciled result of `mobile.supermux.claude.set_option`.
public struct SupermuxClaudeSetOptionResultDTO: Codable, Sendable, Equatable {
    /// Authoritative scalar value reported after the mutation.
    public var appliedValue: SupermuxClaudeOptionValue

    /// Creates a reconciled option result.
    /// - Parameter appliedValue: Authoritative value after mutation.
    public init(appliedValue: SupermuxClaudeOptionValue) {
        self.appliedValue = appliedValue
    }

    private enum CodingKeys: String, CodingKey {
        case appliedValue = "applied_value"
    }
}

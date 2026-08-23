/// Result frame subtypes handled by the harness.
public enum SupermuxHarnessResultSubtype: String, CaseIterable, Sendable {
    /// The turn completed successfully.
    case success
    /// Execution failed before a normal end turn.
    case errorDuringExecution = "error_during_execution"
    /// The configured maximum number of turns was reached.
    case errorMaxTurns = "error_max_turns"
    /// A configured budget was exhausted.
    case errorMaxBudget = "error_max_budget"
}

/// A completed turn result and usage summary.
public struct SupermuxHarnessResultFrame: Sendable {
    /// The recognized result subtype.
    public let subtype: SupermuxHarnessResultSubtype
    /// Whether Claude Code marked the result as an error.
    public let isError: Bool
    /// The final rendered result text when supplied.
    public let result: String?
    /// The session identifier when supplied by the CLI.
    public let sessionID: String?
    /// The terminal reason when supplied by the CLI.
    public let terminalReason: String?
    /// The complete raw frame, including usage and per-model usage.
    public let rawObject: SupermuxHarnessJSONObject

    /// Creates a result frame.
    ///
    /// - Parameters:
    ///   - subtype: The recognized result subtype.
    ///   - isError: Whether the CLI marked the result as an error.
    ///   - result: Optional final result text.
    ///   - sessionID: The optional session identifier.
    ///   - terminalReason: The optional terminal reason.
    ///   - rawObject: The complete raw frame.
    public init(
        subtype: SupermuxHarnessResultSubtype,
        isError: Bool,
        result: String?,
        sessionID: String?,
        terminalReason: String?,
        rawObject: SupermuxHarnessJSONObject
    ) {
        self.subtype = subtype
        self.isError = isError
        self.result = result
        self.sessionID = sessionID
        self.terminalReason = terminalReason
        self.rawObject = rawObject
    }
}

/// Bounded summary of one Claude tool use for mobile rendering.
///
/// Large input or output bodies are never embedded here. The client may use
/// the enclosing message identifier to retrieve the full body through the
/// chunked `mobile.supermux.claude.tool_payload` method.
public struct SupermuxClaudeToolDTO: Codable, Sendable, Equatable {
    /// Claude's stable tool-use identifier.
    public var toolUseID: String
    /// Protocol-level tool name.
    public var name: String
    /// Short user-facing title.
    public var title: String
    /// Bounded input summary.
    public var inputSummary: String?
    /// Bounded output summary.
    public var outputSummary: String?
    /// Whether the completed tool result represents an error.
    public var isError: Bool?
    /// Whether the tool use has received its final result.
    public var isComplete: Bool

    /// Creates a bounded tool summary.
    /// - Parameters:
    ///   - toolUseID: Claude's stable tool-use identifier.
    ///   - name: Protocol-level tool name.
    ///   - title: Short user-facing title.
    ///   - inputSummary: Bounded input summary.
    ///   - outputSummary: Bounded output summary.
    ///   - isError: Whether the completed result is an error.
    ///   - isComplete: Whether the tool use has a final result.
    public init(
        toolUseID: String,
        name: String,
        title: String,
        inputSummary: String? = nil,
        outputSummary: String? = nil,
        isError: Bool? = nil,
        isComplete: Bool
    ) {
        self.toolUseID = toolUseID
        self.name = name
        self.title = title
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.isError = isError
        self.isComplete = isComplete
    }

    private enum CodingKeys: String, CodingKey {
        case toolUseID = "tool_use_id"
        case name
        case title
        case inputSummary = "input_summary"
        case outputSummary = "output_summary"
        case isError = "is_error"
        case isComplete = "is_complete"
    }
}

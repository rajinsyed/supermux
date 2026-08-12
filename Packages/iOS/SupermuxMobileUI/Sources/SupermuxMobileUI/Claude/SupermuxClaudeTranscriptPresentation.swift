public import SupermuxMobileCore

/// One rendered row of a Claude harness transcript.
///
/// The wire message is a compact DTO with a `kind` and some optional fields;
/// this is the shape the views actually draw. Projecting once, outside the
/// view tree, is what keeps every branch decision testable and keeps the row
/// views free of `if let` chains over optional wire fields.
public struct SupermuxClaudeTranscriptRow: Identifiable, Equatable, Sendable {
    /// What the row draws.
    public enum Content: Equatable, Sendable {
        /// A prompt the user sent (right-aligned bubble).
        case userPrompt(String)
        /// Assistant prose, rendered as markdown.
        case assistantProse(String)
        /// Extended thinking, collapsed behind a disclosure.
        case thinking(String)
        /// A tool invocation card.
        case tool(SupermuxClaudeToolDTO)
        /// Harness status or diagnostic text.
        case status(String)
    }

    /// The wire message's stable identifier.
    public let id: String
    /// The message's transcript sequence.
    public let seq: UInt64
    /// What to draw.
    public let content: Content

    /// Creates a row.
    /// - Parameters:
    ///   - id: The message identifier.
    ///   - seq: The transcript sequence.
    ///   - content: What to draw.
    public init(id: String, seq: UInt64, content: Content) {
        self.id = id
        self.seq = seq
        self.content = content
    }
}

/// Projects wire messages into drawable rows.
///
/// lint:allow namespace-enum — stateless projection helpers.
public enum SupermuxClaudeTranscriptPresentation {
    /// Projects one transcript into rows, dropping messages that carry
    /// nothing to draw.
    ///
    /// A message can legitimately arrive empty — a streaming prose message
    /// exists before its first delta lands — and rendering an empty bubble
    /// for it would make the transcript flicker rows in and out.
    ///
    /// - Parameter messages: The store's ordered messages.
    public static func rows(
        for messages: [SupermuxClaudeChatMessageDTO]
    ) -> [SupermuxClaudeTranscriptRow] {
        messages.compactMap(row(for:))
    }

    /// Projects one message, or `nil` when it has nothing to draw.
    /// - Parameter message: The wire message.
    public static func row(
        for message: SupermuxClaudeChatMessageDTO
    ) -> SupermuxClaudeTranscriptRow? {
        guard let content = content(for: message) else { return nil }
        return SupermuxClaudeTranscriptRow(id: message.id, seq: message.seq, content: content)
    }

    private static func content(
        for message: SupermuxClaudeChatMessageDTO
    ) -> SupermuxClaudeTranscriptRow.Content? {
        switch message.kind {
        case .tool:
            guard let tool = message.tool else { return nil }
            return .tool(tool)
        case .thought:
            return nonEmpty(message.text).map { .thinking($0) }
        case .status:
            return nonEmpty(message.text).map { .status($0) }
        case .prose:
            guard let text = nonEmpty(message.text) else { return nil }
            return message.role == .user ? .userPrompt(text) : .assistantProse(text)
        case .unknown:
            // Forward compatibility: a newer Mac may send kinds this build
            // cannot place. Falling back to plain text keeps the CONTENT
            // visible (just unstyled) instead of silently dropping a turn.
            return nonEmpty(message.text).map { .status($0) }
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// The tool card's headline, preferring the Mac's humanized title.
    ///
    /// The humanizer table lives in `SupermuxClaudeHarness` and runs Mac-side
    /// into ``SupermuxClaudeToolDTO/title``, so both platforms get the same
    /// labels from one table and this package does not depend on the harness
    /// package (nor mirror its table, which would then have two owners). The
    /// raw protocol name is only the fallback for an older Mac that sent an
    /// empty title.
    ///
    /// - Parameter tool: The bounded tool summary.
    public static func toolTitle(_ tool: SupermuxClaudeToolDTO) -> String {
        tool.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tool.name : tool.title
    }

    /// Whether a tool card should read as an error.
    /// - Parameter tool: The bounded tool summary.
    public static func isFailed(_ tool: SupermuxClaudeToolDTO) -> Bool {
        tool.isComplete && tool.isError == true
    }

    /// Whether the card offers a "show full output" affordance, which fetches
    /// through `claude.tool_payload` rather than trusting the event summary.
    ///
    /// Only completed tools qualify: a running tool's summary is still
    /// growing, and the Mac has no final payload to serve yet.
    ///
    /// - Parameter tool: The bounded tool summary.
    public static func offersFullPayload(_ tool: SupermuxClaudeToolDTO) -> Bool {
        guard tool.isComplete else { return false }
        guard let summary = tool.outputSummary else { return false }
        return !summary.isEmpty
    }
}

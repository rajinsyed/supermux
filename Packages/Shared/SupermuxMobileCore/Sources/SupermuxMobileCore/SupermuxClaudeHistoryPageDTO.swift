/// One page returned by `mobile.supermux.claude.history`.
///
/// The envelope mirrors `mobile.chat.history`: messages are ordered oldest to
/// newest and ``hasMore`` indicates that an older page exists.
public struct SupermuxClaudeHistoryPageDTO: Codable, Sendable, Equatable {
    /// Messages in ascending sequence order.
    public var messages: [SupermuxClaudeChatMessageDTO]
    /// Whether messages older than this page remain available.
    public var hasMore: Bool

    /// Creates a history page.
    /// - Parameters:
    ///   - messages: Messages in ascending sequence order.
    ///   - hasMore: Whether an older page remains available.
    public init(messages: [SupermuxClaudeChatMessageDTO], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }
}

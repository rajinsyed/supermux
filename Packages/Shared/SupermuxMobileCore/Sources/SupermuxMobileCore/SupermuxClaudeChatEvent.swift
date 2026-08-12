/// A compact fork-owned event applied to one Claude harness transcript.
///
/// Append and update events may be coalesced by the Mac before publication.
/// Unknown event kinds decode without failing the containing stream frame.
public enum SupermuxClaudeChatEvent: Codable, Sendable, Equatable {
    /// Appends messages whose sequence numbers follow the client's anchor.
    case append([SupermuxClaudeChatMessageDTO])
    /// Replaces previously delivered messages with matching identifiers.
    case update([SupermuxClaudeChatMessageDTO])
    /// Updates the mobile-visible session lifecycle state.
    case state(SupermuxClaudeSessionState)
    /// Invalidates the local transcript and requires a history re-anchor.
    case reset
    /// A newer event kind not understood by this client.
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case messages
        case state
    }

    /// Decodes a compact event and preserves unknown event names.
    /// - Parameter decoder: The decoder supplying the event object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "append":
            self = .append(try container.decode([SupermuxClaudeChatMessageDTO].self, forKey: .messages))
        case "update":
            self = .update(try container.decode([SupermuxClaudeChatMessageDTO].self, forKey: .messages))
        case "state":
            self = .state(try container.decode(SupermuxClaudeSessionState.self, forKey: .state))
        case "reset":
            self = .reset
        default:
            self = .unknown(kind)
        }
    }

    /// Encodes an event using a compact `kind` discriminator.
    /// - Parameter encoder: The encoder receiving the event object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .append(let messages):
            try container.encode("append", forKey: .kind)
            try container.encode(messages, forKey: .messages)
        case .update(let messages):
            try container.encode("update", forKey: .kind)
            try container.encode(messages, forKey: .messages)
        case .state(let state):
            try container.encode("state", forKey: .kind)
            try container.encode(state, forKey: .state)
        case .reset:
            try container.encode("reset", forKey: .kind)
        case .unknown(let kind):
            try container.encode(kind, forKey: .kind)
        }
    }
}

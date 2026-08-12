/// The presentation kind of a compact Claude harness chat message.
public enum SupermuxClaudeChatMessageKind: Codable, Sendable, Equatable {
    /// User-visible prose.
    case prose
    /// Extended-thinking content that the client may collapse.
    case thought
    /// A tool invocation or result summary.
    case tool
    /// Harness status or diagnostic text.
    case status
    /// A newer kind not understood by this client.
    case unknown(String)

    /// Decodes a message kind while preserving unknown raw values.
    /// - Parameter decoder: The decoder supplying the kind string.
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "prose": self = .prose
        case "thought": self = .thought
        case "tool": self = .tool
        case "status": self = .status
        default: self = .unknown(rawValue)
        }
    }

    /// Encodes the message kind as a compact string.
    /// - Parameter encoder: The encoder receiving the kind string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .prose: try container.encode("prose")
        case .thought: try container.encode("thought")
        case .tool: try container.encode("tool")
        case .status: try container.encode("status")
        case .unknown(let rawValue): try container.encode(rawValue)
        }
    }
}

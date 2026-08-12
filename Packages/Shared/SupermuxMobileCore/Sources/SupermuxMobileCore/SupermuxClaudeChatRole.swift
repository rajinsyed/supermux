/// The author of a compact Claude harness chat message.
public enum SupermuxClaudeChatRole: Codable, Sendable, Equatable {
    /// A prompt submitted by the user.
    case user
    /// Output produced by Claude.
    case assistant
    /// Harness-owned status or diagnostic output.
    case system
    /// A newer role not understood by this client.
    case unknown(String)

    /// Decodes a role while preserving unknown raw values.
    /// - Parameter decoder: The decoder supplying the role string.
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "user": self = .user
        case "assistant": self = .assistant
        case "system": self = .system
        default: self = .unknown(rawValue)
        }
    }

    /// Encodes the role as a compact string.
    /// - Parameter encoder: The encoder receiving the role string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .user: try container.encode("user")
        case .assistant: try container.encode("assistant")
        case .system: try container.encode("system")
        case .unknown(let rawValue): try container.encode(rawValue)
        }
    }
}

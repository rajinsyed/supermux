/// Scalar value accepted by `mobile.supermux.claude.set_option`.
public enum SupermuxClaudeOptionValue: Codable, Sendable, Equatable {
    /// A model or effort string.
    case string(String)
    /// A fast-mode toggle.
    case bool(Bool)
    /// A thinking-token maximum.
    case integer(Int)
    /// Clears an optional setting.
    case null

    /// Decodes one JSON scalar option value.
    /// - Parameter decoder: The decoder supplying the scalar.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    /// Encodes one JSON scalar option value.
    /// - Parameter encoder: The encoder receiving the scalar.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

import Foundation

/// A losslessly decoded JSON value.
///
/// The Claude Code stream-json wire evolves faster than any typed model can;
/// every typed line in this package therefore keeps its unrecognized fields as
/// `ClaudeJSONValue` so nothing observed on the wire is dropped. The root
/// `tool_use_result` field is a true union (object for a successful Write,
/// scalar string for a denied execution), which only this type can represent.
public indirect enum ClaudeJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// A JSON integer, kept as `Int64` so 64-bit counters and IDs round-trip
    /// without the `Double` 2^53 precision loss.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ClaudeJSONValue])
    case object([String: ClaudeJSONValue])
}

extension ClaudeJSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ClaudeJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ClaudeJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension ClaudeJSONValue {
    /// The string payload, when this value is a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The numeric payload, when this value is a number or integer.
    public var numberValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    /// The numeric payload as `Int`, when exactly representable.
    public var intValue: Int? {
        switch self {
        case .integer(let value):
            return Int(exactly: value)
        case .number(let number):
            guard number.truncatingRemainder(dividingBy: 1) == 0,
                  number >= Double(Int.min), number <= Double(Int.max) else { return nil }
            return Int(number)
        default:
            return nil
        }
    }

    /// The boolean payload, when this value is a bool.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The array payload, when this value is an array.
    public var arrayValue: [ClaudeJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The object payload, when this value is an object.
    public var objectValue: [String: ClaudeJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Member lookup for object values; `nil` for every other case.
    public subscript(key: String) -> ClaudeJSONValue? {
        objectValue?[key]
    }
}

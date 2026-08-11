import Foundation

/// An outbound harness-to-CLI control request.
///
/// The wire form is `{"type":"control_request","request_id":...,"request":{...}}`
/// with the subtype and its parameters inside `request`.
public enum ClaudeOutboundControl: Sendable, Equatable {
    case initialize
    case getBinaryVersion
    case listModels
    case setModel(String)
    case setMaxThinkingTokens(Int)
    case setEffort(String)
    case setFastMode(Bool)
    case interrupt

    /// The wire subtype string.
    public var subtype: String {
        switch self {
        case .initialize: return "initialize"
        case .getBinaryVersion: return "get_binary_version"
        case .listModels: return "list_models"
        case .setModel: return "set_model"
        case .setMaxThinkingTokens: return "set_max_thinking_tokens"
        case .setEffort, .setFastMode: return "apply_flag_settings"
        case .interrupt: return "interrupt"
        }
    }

    /// The complete `request` payload object.
    public var requestPayload: ClaudeJSONValue {
        switch self {
        case .initialize, .getBinaryVersion, .listModels, .interrupt:
            return .object(["subtype": .string(subtype)])
        case .setModel(let model):
            return .object(["subtype": .string(subtype), "model": .string(model)])
        case .setMaxThinkingTokens(let tokens):
            return .object([
                "subtype": .string(subtype),
                "max_thinking_tokens": .integer(Int64(tokens)),
            ])
        case .setEffort(let level):
            return .object([
                "subtype": .string(subtype),
                "settings": .object(["effortLevel": .string(level)]),
            ])
        case .setFastMode(let enabled):
            return .object([
                "subtype": .string(subtype),
                "settings": .object(["fastMode": .bool(enabled)]),
            ])
        }
    }

    /// Serializes the full control-request line (no trailing newline).
    public func encodedLine(requestID: String) -> Data {
        let line = ClaudeJSONValue.object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": requestPayload,
        ])
        // ClaudeJSONValue encoding cannot fail for the value shapes above.
        return (try? JSONEncoder().encode(line)) ?? Data()
    }
}

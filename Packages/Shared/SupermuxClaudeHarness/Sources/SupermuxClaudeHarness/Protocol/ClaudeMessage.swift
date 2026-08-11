import Foundation

/// A complete top-level `user`/`assistant` line.
///
/// Multiple top-level assistant lines can share one API message ID while each
/// carries only the just-completed block; consumers reconcile by message ID and
/// block identity rather than appending each line as a separate turn.
public struct ClaudeMessageEnvelope: Sendable, Equatable {
    public let message: ClaudeMessage
    public let sessionID: String?
    public let parentToolUseID: String?
    public let uuid: String?
    public let timestamp: String?
    public let isReplay: Bool?
    public let isSidechain: Bool?
    public let isMeta: Bool?
    /// The root `tool_use_result` field: a true JSON union — an object for a
    /// successful Write, a scalar error string for a denied execution.
    public let toolUseResult: ClaudeJSONValue?
    /// The root `tool_result_meta` field (e.g. `non_execution_kind`).
    public let toolResultMeta: ClaudeJSONValue?
    /// The full envelope object as observed on the wire.
    public let raw: ClaudeJSONValue

    init?(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        guard let messageObject = object["message"]?.objectValue else { return nil }
        self.message = ClaudeMessage(object: messageObject, raw: object["message"] ?? .null)
        self.sessionID = object["session_id"]?.stringValue
        self.parentToolUseID = object["parent_tool_use_id"]?.stringValue
        self.uuid = object["uuid"]?.stringValue
        self.timestamp = object["timestamp"]?.stringValue
        self.isReplay = object["isReplay"]?.boolValue
        self.isSidechain = object["isSidechain"]?.boolValue
        self.isMeta = object["isMeta"]?.boolValue
        self.toolUseResult = object["tool_use_result"]
        self.toolResultMeta = object["tool_result_meta"]
        self.raw = raw
    }
}

/// The Messages-API-shaped `message` object inside an envelope or
/// `message_start` event.
public struct ClaudeMessage: Sendable, Equatable {
    public let id: String?
    public let role: String?
    public let model: String?
    public let content: [ClaudeContentBlock]
    public let stopReason: String?
    public let stopSequence: String?
    public let usage: ClaudeUsage?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.id = object["id"]?.stringValue
        self.role = object["role"]?.stringValue
        self.model = object["model"]?.stringValue
        if let blocks = object["content"]?.arrayValue {
            self.content = blocks.map(ClaudeContentBlock.init(value:))
        } else if let text = object["content"]?.stringValue {
            self.content = [.text(text: text, citations: nil)]
        } else {
            self.content = []
        }
        self.stopReason = object["stop_reason"]?.stringValue
        self.stopSequence = object["stop_sequence"]?.stringValue
        self.usage = (object["usage"]?.objectValue).map {
            ClaudeUsage(object: $0, raw: object["usage"] ?? .null)
        }
        self.raw = raw
    }
}

/// One content block of a complete message.
public enum ClaudeContentBlock: Sendable, Equatable {
    case text(text: String, citations: ClaudeJSONValue?)
    case thinking(thinking: String, signature: String?)
    case toolUse(id: String, name: String, input: ClaudeJSONValue, caller: ClaudeJSONValue?)
    case toolResult(toolUseID: String?, content: ClaudeToolResultContent, isError: Bool?)
    case image(source: ClaudeJSONValue)
    case document(source: ClaudeJSONValue)
    case unknown(type: String?, payload: ClaudeJSONValue)

    init(value: ClaudeJSONValue) {
        guard let object = value.objectValue else {
            self = .unknown(type: nil, payload: value)
            return
        }
        switch object["type"]?.stringValue {
        case "text":
            self = .text(
                text: object["text"]?.stringValue ?? "",
                citations: object["citations"]
            )
        case "thinking":
            self = .thinking(
                thinking: object["thinking"]?.stringValue ?? "",
                signature: object["signature"]?.stringValue
            )
        case "tool_use":
            self = .toolUse(
                id: object["id"]?.stringValue ?? "",
                name: object["name"]?.stringValue ?? "",
                input: object["input"] ?? .null,
                caller: object["caller"]
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: object["tool_use_id"]?.stringValue,
                content: ClaudeToolResultContent(value: object["content"] ?? .null),
                isError: object["is_error"]?.boolValue
            )
        case "image":
            self = .image(source: object["source"] ?? .null)
        case "document":
            self = .document(source: object["source"] ?? .null)
        default:
            self = .unknown(type: object["type"]?.stringValue, payload: value)
        }
    }
}

/// Tool-result content: either one string or a heterogeneous block array.
public enum ClaudeToolResultContent: Sendable, Equatable {
    case text(String)
    case blocks([ClaudeToolResultBlock])

    init(value: ClaudeJSONValue) {
        if let text = value.stringValue {
            self = .text(text)
        } else if let array = value.arrayValue {
            self = .blocks(array.map(ClaudeToolResultBlock.init(value:)))
        } else {
            self = .blocks([.unknown(type: nil, payload: value)])
        }
    }

    /// The concatenated text of all text portions, for display fallbacks.
    public var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block in
                if case .text(let text) = block { return text }
                return nil
            }.joined(separator: "\n")
        }
    }
}

/// One block inside a structured tool result.
public enum ClaudeToolResultBlock: Sendable, Equatable {
    case text(String)
    case image(source: ClaudeJSONValue)
    case document(source: ClaudeJSONValue)
    case unknown(type: String?, payload: ClaudeJSONValue)

    init(value: ClaudeJSONValue) {
        guard let object = value.objectValue else {
            self = .unknown(type: nil, payload: value)
            return
        }
        switch object["type"]?.stringValue {
        case "text":
            self = .text(object["text"]?.stringValue ?? "")
        case "image":
            self = .image(source: object["source"] ?? .null)
        case "document":
            self = .document(source: object["source"] ?? .null)
        default:
            self = .unknown(type: object["type"]?.stringValue, payload: value)
        }
    }
}

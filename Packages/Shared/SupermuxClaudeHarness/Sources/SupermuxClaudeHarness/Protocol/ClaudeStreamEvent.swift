import Foundation

/// A top-level `stream_event` line: partial-message streaming.
///
/// The Messages API event lives NESTED under `event` — `stream_event.event.type`
/// is `content_block_delta` etc., never at the top level. Decoding the wrong
/// nesting level was the exact bug in the app's previous accumulator.
public struct ClaudeStreamEventEnvelope: Sendable, Equatable {
    public let event: ClaudeStreamEvent
    public let sessionID: String?
    public let parentToolUseID: String?
    public let uuid: String?
    /// Time-to-first-token, present on `message_start` envelopes.
    public let ttftMs: Int?
    public let raw: ClaudeJSONValue

    init?(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        guard let eventValue = object["event"], let eventObject = eventValue.objectValue else {
            return nil
        }
        self.event = ClaudeStreamEvent(object: eventObject, raw: eventValue)
        self.sessionID = object["session_id"]?.stringValue
        self.parentToolUseID = object["parent_tool_use_id"]?.stringValue
        self.uuid = object["uuid"]?.stringValue
        self.ttftMs = object["ttft_ms"]?.intValue
        self.raw = raw
    }
}

/// The nested Messages API streaming event.
public enum ClaudeStreamEvent: Sendable, Equatable {
    case messageStart(message: ClaudeMessage)
    case contentBlockStart(index: Int, block: ClaudeContentBlock)
    case contentBlockDelta(index: Int, delta: ClaudeStreamDelta)
    case contentBlockStop(index: Int)
    case messageDelta(delta: ClaudeMessageDelta, usage: ClaudeUsage?, contextManagement: ClaudeJSONValue?)
    case messageStop
    case unknown(type: String?, payload: ClaudeJSONValue)

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        switch object["type"]?.stringValue {
        case "message_start":
            guard let message = object["message"]?.objectValue else {
                self = .unknown(type: "message_start", payload: raw)
                return
            }
            self = .messageStart(
                message: ClaudeMessage(object: message, raw: object["message"] ?? .null)
            )
        case "content_block_start":
            self = .contentBlockStart(
                index: object["index"]?.intValue ?? 0,
                block: ClaudeContentBlock(value: object["content_block"] ?? .null)
            )
        case "content_block_delta":
            self = .contentBlockDelta(
                index: object["index"]?.intValue ?? 0,
                delta: ClaudeStreamDelta(value: object["delta"] ?? .null)
            )
        case "content_block_stop":
            self = .contentBlockStop(index: object["index"]?.intValue ?? 0)
        case "message_delta":
            self = .messageDelta(
                delta: ClaudeMessageDelta(value: object["delta"] ?? .null),
                usage: (object["usage"]?.objectValue).map {
                    ClaudeUsage(object: $0, raw: object["usage"] ?? .null)
                },
                contextManagement: object["context_management"]
            )
        case "message_stop":
            self = .messageStop
        default:
            self = .unknown(type: object["type"]?.stringValue, payload: raw)
        }
    }
}

/// One `content_block_delta.delta` payload.
public enum ClaudeStreamDelta: Sendable, Equatable {
    case text(String)
    /// Thinking text may be empty while `estimatedTokens` carries real
    /// progress; empty text must not hide or terminate the thinking block.
    case thinking(text: String, estimatedTokens: Int?)
    case signature(String)
    /// Verbatim `partial_json` fragment; append, decode only at block stop.
    case inputJSON(String)
    case unknown(type: String?, payload: ClaudeJSONValue)

    init(value: ClaudeJSONValue) {
        guard let object = value.objectValue else {
            self = .unknown(type: nil, payload: value)
            return
        }
        switch object["type"]?.stringValue {
        case "text_delta":
            self = .text(object["text"]?.stringValue ?? "")
        case "thinking_delta":
            self = .thinking(
                text: object["thinking"]?.stringValue ?? "",
                estimatedTokens: object["estimated_tokens"]?.intValue
            )
        case "signature_delta":
            self = .signature(object["signature"]?.stringValue ?? "")
        case "input_json_delta":
            self = .inputJSON(object["partial_json"]?.stringValue ?? "")
        default:
            self = .unknown(type: object["type"]?.stringValue, payload: value)
        }
    }
}

/// The `message_delta.delta` payload carrying the authoritative stop reason.
public struct ClaudeMessageDelta: Sendable, Equatable {
    public let stopReason: String?
    public let stopSequence: String?
    public let raw: ClaudeJSONValue

    init(value: ClaudeJSONValue) {
        self.stopReason = value["stop_reason"]?.stringValue
        self.stopSequence = value["stop_sequence"]?.stringValue
        self.raw = value
    }
}

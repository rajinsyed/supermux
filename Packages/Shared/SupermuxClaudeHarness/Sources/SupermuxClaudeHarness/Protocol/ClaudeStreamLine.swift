import Foundation

/// One typed top-level stream-json line.
///
/// Permissions are always skipped in this harness (every session launches with
/// `--dangerously-skip-permissions`), so an inbound `control_request` — if one
/// ever appears — decodes as the inert ``controlRequest(_:)`` case and is
/// surfaced as a diagnostic, never answered.
public enum ClaudeStreamLine: Sendable, Equatable {
    case system(ClaudeSystemEvent)
    case user(ClaudeMessageEnvelope)
    case assistant(ClaudeMessageEnvelope)
    case streamEvent(ClaudeStreamEventEnvelope)
    case result(ClaudeResult)
    /// A CLI-to-harness control request, kept inert (decode + diagnose only).
    case controlRequest(ClaudeInboundControlRequest)
    case controlResponse(ClaudeControlResponseEnvelope)
    case unknown(rawType: String?, payload: ClaudeJSONValue)

    /// Decodes one classified JSON line into its typed form.
    public static func decode(_ value: ClaudeJSONValue) -> ClaudeStreamLine {
        guard let object = value.objectValue else {
            return .unknown(rawType: nil, payload: value)
        }
        switch object["type"]?.stringValue {
        case "system":
            return .system(ClaudeSystemEvent(object: object, raw: value))
        case "user":
            guard let envelope = ClaudeMessageEnvelope(object: object, raw: value) else {
                return .unknown(rawType: "user", payload: value)
            }
            return .user(envelope)
        case "assistant":
            guard let envelope = ClaudeMessageEnvelope(object: object, raw: value) else {
                return .unknown(rawType: "assistant", payload: value)
            }
            return .assistant(envelope)
        case "stream_event":
            guard let envelope = ClaudeStreamEventEnvelope(object: object, raw: value) else {
                return .unknown(rawType: "stream_event", payload: value)
            }
            return .streamEvent(envelope)
        case "result":
            return .result(ClaudeResult(object: object, raw: value))
        case "control_request":
            return .controlRequest(ClaudeInboundControlRequest(object: object, raw: value))
        case "control_response":
            return .controlResponse(ClaudeControlResponseEnvelope(object: object, raw: value))
        default:
            return .unknown(rawType: object["type"]?.stringValue, payload: value)
        }
    }
}

/// An inbound `control_request` line, preserved but never answered.
public struct ClaudeInboundControlRequest: Sendable, Equatable {
    public let requestID: String?
    public let subtype: String?
    public let raw: ClaudeJSONValue

    init(object: [String: ClaudeJSONValue], raw: ClaudeJSONValue) {
        self.requestID = object["request_id"]?.stringValue
        self.subtype = object["request"]?["subtype"]?.stringValue
        self.raw = raw
    }
}

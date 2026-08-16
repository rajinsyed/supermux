import Foundation

/// Tolerantly decodes Claude Code stream-json stdout lines.
///
/// Unknown top-level types and unknown subtypes produce a decoded line whose ``SupermuxHarnessDecodedLine/frame``
/// is `nil`; the complete JSON object remains available for pass-through.
public struct SupermuxHarnessProtocolDecoder: Sendable {
    /// Creates a protocol decoder.
    public init() {}

    /// Parses one stdout line and recognizes supported protocol frames.
    ///
    /// - Parameter line: A complete JSON line. Trailing CR/LF whitespace is accepted.
    /// - Returns: The preserved object and optional typed frame.
    /// - Throws: ``SupermuxHarnessProtocolError`` for malformed JSON or a non-object root.
    public func decodeLine(_ line: String) throws -> SupermuxHarnessDecodedLine {
        guard let data = line.data(using: .utf8) else {
            throw SupermuxHarnessProtocolError.invalidJSON
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw SupermuxHarnessProtocolError.invalidJSON
        }
        guard let dictionary = value as? [String: Any] else {
            throw SupermuxHarnessProtocolError.expectedJSONObject
        }
        let object = SupermuxHarnessJSONObject(parsedObject: dictionary)
        return SupermuxHarnessDecodedLine(
            rawLine: line,
            object: object,
            frame: decodeObject(object)
        )
    }

    /// Recognizes a previously parsed JSON object.
    ///
    /// - Parameter object: The complete protocol object.
    /// - Returns: A typed frame, or `nil` for an unknown type or subtype.
    public func decodeObject(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        switch object.string(forKey: "type") {
        case "system":
            return decodeSystem(object)
        case "stream_event":
            return decodeStreamEvent(object)
        case "assistant":
            return decodeAssistant(object)
        case "user":
            return decodeUser(object)
        case "result":
            return decodeResult(object)
        case "control_request":
            return decodeControlRequest(object)
        case "control_response":
            return decodeControlResponse(object)
        case "control_cancel_request":
            return decodeControlCancelRequest(object)
        case "keep_alive":
            return .keepAlive(SupermuxHarnessKeepAliveFrame(rawObject: object))
        default:
            return nil
        }
    }

    private func decodeSystem(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        guard let rawSubtype = object.string(forKey: "subtype"),
              let subtype = SupermuxHarnessSystemSubtype(rawValue: rawSubtype) else {
            return nil
        }
        return .system(SupermuxHarnessSystemFrame(
            subtype: subtype,
            sessionID: object.string(forKey: "session_id"),
            uuid: object.string(forKey: "uuid"),
            rawObject: object
        ))
    }

    private func decodeStreamEvent(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        guard let event = object.object(forKey: "event"),
              let rawType = event.string(forKey: "type"),
              let eventType = SupermuxHarnessStreamEventType(rawValue: rawType) else {
            return nil
        }
        return .streamEvent(SupermuxHarnessStreamEventFrame(
            eventType: eventType,
            event: event,
            sessionID: object.string(forKey: "session_id"),
            parentToolUseID: object.string(forKey: "parent_tool_use_id"),
            rawObject: object
        ))
    }

    private func decodeAssistant(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        guard let message = object.object(forKey: "message") else { return nil }
        return .assistant(SupermuxHarnessAssistantFrame(
            message: message,
            sessionID: object.string(forKey: "session_id"),
            parentToolUseID: object.string(forKey: "parent_tool_use_id"),
            uuid: object.string(forKey: "uuid"),
            rawObject: object
        ))
    }

    private func decodeUser(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        guard let message = object.object(forKey: "message") else { return nil }
        return .user(SupermuxHarnessUserFrame(
            message: message,
            toolUseResult: object.object(forKey: "tool_use_result"),
            sessionID: object.string(forKey: "session_id"),
            parentToolUseID: object.string(forKey: "parent_tool_use_id"),
            uuid: object.string(forKey: "uuid"),
            rawObject: object
        ))
    }

    private func decodeResult(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        guard let rawSubtype = object.string(forKey: "subtype"),
              let subtype = SupermuxHarnessResultSubtype(rawValue: rawSubtype) else {
            return nil
        }
        return .result(SupermuxHarnessResultFrame(
            subtype: subtype,
            isError: object.bool(forKey: "is_error") ?? false,
            result: object.string(forKey: "result"),
            sessionID: object.string(forKey: "session_id"),
            terminalReason: object.string(forKey: "terminal_reason"),
            rawObject: object
        ))
    }

    private func decodeControlRequest(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        guard let requestID = object.string(forKey: "request_id"),
              let request = object.object(forKey: "request"),
              request.string(forKey: "subtype") == SupermuxHarnessIncomingControlRequestSubtype.canUseTool.rawValue else {
            return nil
        }
        let suggestions = request.objects(forKey: "permission_suggestions") ?? []
        let permission = SupermuxHarnessPermissionRequest(
            requestID: requestID,
            toolName: request.string(forKey: "tool_name"),
            displayName: request.string(forKey: "display_name"),
            input: request.object(forKey: "input"),
            title: request.string(forKey: "title"),
            requestDescription: request.string(forKey: "description"),
            permissionSuggestions: suggestions,
            blockedPath: request.string(forKey: "blocked_path"),
            decisionReason: request.string(forKey: "decision_reason"),
            suppressAlwaysAllowRule: request.bool(forKey: "suppress_always_allow_rule") ?? false,
            toolUseID: request.string(forKey: "tool_use_id"),
            agentID: request.string(forKey: "agent_id"),
            rawObject: object
        )
        return .controlRequest(SupermuxHarnessControlRequestFrame(
            subtype: .canUseTool,
            requestID: requestID,
            permissionRequest: permission,
            rawObject: object
        ))
    }

    private func decodeControlResponse(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        guard let envelope = object.object(forKey: "response"),
              let rawSubtype = envelope.string(forKey: "subtype"),
              let subtype = SupermuxHarnessControlResponseSubtype(rawValue: rawSubtype),
              let requestID = envelope.string(forKey: "request_id") else {
            return nil
        }
        return .controlResponse(SupermuxHarnessControlResponseFrame(
            subtype: subtype,
            requestID: requestID,
            response: envelope.object(forKey: "response"),
            rawObject: object
        ))
    }

    private func decodeControlCancelRequest(_ object: SupermuxHarnessJSONObject) -> SupermuxHarnessFrame? {
        guard let requestID = object.string(forKey: "request_id") else { return nil }
        return .controlCancelRequest(SupermuxHarnessControlCancelRequestFrame(
            requestID: requestID,
            rawObject: object
        ))
    }
}

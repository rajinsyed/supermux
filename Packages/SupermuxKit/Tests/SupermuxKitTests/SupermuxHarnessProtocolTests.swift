import Foundation
import Testing

@testable import SupermuxKit

@Suite struct SupermuxHarnessProtocolTests {
    private let decoder = SupermuxHarnessProtocolDecoder()

    @Test func immutableJSONObjectPreservesValuesAndFreezesMutableInput() throws {
        let mutable = NSMutableDictionary(dictionary: ["value": 1])
        let object = try SupermuxHarnessJSONObject(rawValue: [
            "string": "text",
            "boolean": true,
            "integer": 42,
            "integralDouble": 42.0,
            "fraction": 42.5,
            "tooLarge": NSDecimalNumber(string: "9223372036854775808"),
            "nested": mutable,
            "objects": [["id": 1], "ignored", ["id": 2]],
        ])
        mutable["value"] = 99

        #expect(object.string(forKey: "string") == "text")
        #expect(object.bool(forKey: "boolean") == true)
        #expect(object.integer(forKey: "integer") == 42)
        #expect(object.integer(forKey: "integralDouble") == 42)
        #expect(object.integer(forKey: "fraction") == nil)
        #expect(object.integer(forKey: "tooLarge") == nil)
        #expect(object.integer(forKey: "boolean") == nil)
        #expect(object.object(forKey: "nested")?.integer(forKey: "value") == 1)
        #expect(object.objects(forKey: "objects")?.count == 2)
        #expect(try SupermuxHarnessJSONObject(rawValue: object.rawValue) == object)
    }

    @Test func invalidJSONObjectIsRejected() {
        #expect(throws: SupermuxHarnessProtocolError.invalidJSONObject) {
            _ = try SupermuxHarnessJSONObject(rawValue: ["date": Date()])
        }
    }

    @Test(arguments: ["not json", "{\"type\":"])
    func malformedJSONIsRejected(_ line: String) {
        #expect(throws: SupermuxHarnessProtocolError.invalidJSON) {
            _ = try decoder.decodeLine(line)
        }
    }

    @Test(arguments: ["[]", "42", "true", "\"text\""])
    func nonObjectRootsAreRejected(_ line: String) {
        #expect(throws: SupermuxHarnessProtocolError.expectedJSONObject) {
            _ = try decoder.decodeLine(line)
        }
    }

    @Test func unknownTypesAndSubtypesRemainAvailableForPassThrough() throws {
        for line in [
            #"{"type":"future_frame","payload":{"kept":true}}"#,
            #"{"type":"system","subtype":"future_system","payload":{"kept":true}}"#,
            #"{"type":"stream_event","event":{"type":"future_event","kept":true}}"#,
            #"{"type":"result","subtype":"future_result","result":"kept"}"#,
        ] {
            let decoded = try decoder.decodeLine(line)
            #expect(decoded.frame == nil)
            #expect(decoded.object.string(forKey: "type") != nil)
            #expect(decoded.rawLine == line)
        }
    }

    @Test(arguments: SupermuxHarnessSystemSubtype.allCases)
    func decodesEverySupportedSystemSubtype(_ subtype: SupermuxHarnessSystemSubtype) throws {
        let line = #"{"type":"system","subtype":"\#(subtype.rawValue)","session_id":"session","uuid":"frame","future":7}"#
        let decoded = try decoder.decodeLine(line)
        guard case .system(let frame) = decoded.frame else {
            Issue.record("Expected system frame for \(subtype.rawValue)")
            return
        }
        #expect(frame.subtype == subtype)
        #expect(frame.sessionID == "session")
        #expect(frame.uuid == "frame")
        #expect(frame.rawObject.integer(forKey: "future") == 7)
        #expect(decoded.object == frame.rawObject)
    }

    @Test(arguments: SupermuxHarnessStreamEventType.allCases)
    func decodesEverySupportedStreamEvent(_ eventType: SupermuxHarnessStreamEventType) throws {
        let line = #"{"type":"stream_event","session_id":"session","parent_tool_use_id":"parent","event":{"type":"\#(eventType.rawValue)","future":"kept"}}"#
        let decoded = try decoder.decodeLine(line)
        guard case .streamEvent(let frame) = decoded.frame else {
            Issue.record("Expected stream event for \(eventType.rawValue)")
            return
        }
        #expect(frame.eventType == eventType)
        #expect(frame.sessionID == "session")
        #expect(frame.parentToolUseID == "parent")
        #expect(frame.event.string(forKey: "future") == "kept")
        #expect(frame.rawObject == decoded.object)
    }

    @Test func decodesAssistantAndUserFrames() throws {
        let assistant = try decoder.decodeLine(
            #"{"type":"assistant","session_id":"s","parent_tool_use_id":"p","uuid":"a","message":{"id":"m","role":"assistant","content":[]},"supersedes":["old"]}"#
        )
        guard case .assistant(let assistantFrame) = assistant.frame else {
            Issue.record("Expected assistant frame")
            return
        }
        #expect(assistantFrame.sessionID == "s")
        #expect(assistantFrame.parentToolUseID == "p")
        #expect(assistantFrame.uuid == "a")
        #expect(assistantFrame.message.string(forKey: "id") == "m")
        #expect(assistantFrame.rawObject.objects(forKey: "supersedes")?.isEmpty == true)

        let user = try decoder.decodeLine(
            #"{"type":"user","session_id":"s","parent_tool_use_id":"p","uuid":"u","message":{"role":"user","content":"done"},"tool_use_result":{"stdout":"ok","interrupted":false}}"#
        )
        guard case .user(let userFrame) = user.frame else {
            Issue.record("Expected user frame")
            return
        }
        #expect(userFrame.sessionID == "s")
        #expect(userFrame.parentToolUseID == "p")
        #expect(userFrame.uuid == "u")
        #expect(userFrame.message.string(forKey: "role") == "user")
        #expect(userFrame.toolUseResult?.string(forKey: "stdout") == "ok")
        #expect(userFrame.toolUseResult?.bool(forKey: "interrupted") == false)
    }

    @Test(arguments: SupermuxHarnessResultSubtype.allCases)
    func decodesEverySupportedResultSubtype(_ subtype: SupermuxHarnessResultSubtype) throws {
        let line = #"{"type":"result","subtype":"\#(subtype.rawValue)","is_error":true,"result":"final","session_id":"s","terminal_reason":"reason","usage":{"input_tokens":3}}"#
        let decoded = try decoder.decodeLine(line)
        guard case .result(let frame) = decoded.frame else {
            Issue.record("Expected result frame for \(subtype.rawValue)")
            return
        }
        #expect(frame.subtype == subtype)
        #expect(frame.isError)
        #expect(frame.result == "final")
        #expect(frame.sessionID == "s")
        #expect(frame.terminalReason == "reason")
        #expect(frame.rawObject.object(forKey: "usage")?.integer(forKey: "input_tokens") == 3)
    }

    @Test func resultDefaultsMissingIsErrorToFalse() throws {
        let decoded = try decoder.decodeLine(#"{"type":"result","subtype":"success"}"#)
        guard case .result(let frame) = decoded.frame else {
            Issue.record("Expected result frame")
            return
        }
        #expect(!frame.isError)
    }

    @Test func decodesRealPermissionFixtureWithAllOptionalFields() throws {
        let incoming = try fixtureTranscriptLines(named: "perm_log", extension: "txt")
            .first { $0.direction == "<<" && $0.json.contains(#""can_use_tool""#) }
        let line = try #require(incoming?.json)
        let decoded = try decoder.decodeLine(line)
        guard case .controlRequest(let frame) = decoded.frame else {
            Issue.record("Expected permission control request")
            return
        }
        let permission = frame.permissionRequest
        #expect(frame.subtype == .canUseTool)
        #expect(permission.requestID == "c40dc1a1-e17a-4c9b-85f6-71de6b4670b0")
        #expect(permission.toolName == "Bash")
        #expect(permission.displayName == "Bash")
        #expect(permission.input?.string(forKey: "command") == "echo \"hello\" > probe2.txt")
        #expect(permission.requestDescription == "Create probe2.txt with content \"hello\"")
        #expect(permission.permissionSuggestions.count == 2)
        #expect(permission.blockedPath == "/private/tmp/harness-proto-probe/probe2.txt")
        #expect(permission.decisionReason == nil)
        #expect(!permission.suppressAlwaysAllowRule)
        #expect(permission.toolUseID == "toolu_01EMXbV6fYLgZfejiSkxRFR2")
        #expect(permission.agentID == nil)
        #expect(permission.rawObject == decoded.object)
    }

    @Test func decodesSyntheticPermissionFieldsAndControlCancellation() throws {
        let permissionLine = #"{"type":"control_request","request_id":"permission","request":{"subtype":"can_use_tool","tool_name":"Edit","title":"Approve edit","description":"Change file","input":{"file_path":"a"},"decision_reason":"outside root","suppress_always_allow_rule":true,"tool_use_id":"tool","agent_id":"agent"}}"#
        let decoded = try decoder.decodeLine(permissionLine)
        guard case .controlRequest(let frame) = decoded.frame else {
            Issue.record("Expected permission request")
            return
        }
        #expect(frame.permissionRequest.title == "Approve edit")
        #expect(frame.permissionRequest.decisionReason == "outside root")
        #expect(frame.permissionRequest.suppressAlwaysAllowRule)
        #expect(frame.permissionRequest.agentID == "agent")

        let cancelled = try decoder.decodeLine(
            #"{"type":"control_cancel_request","request_id":"permission","future":"kept"}"#
        )
        guard case .controlCancelRequest(let cancellation) = cancelled.frame else {
            Issue.record("Expected control cancellation")
            return
        }
        #expect(cancellation.requestID == "permission")
        #expect(cancellation.rawObject.string(forKey: "future") == "kept")
    }

    @Test(arguments: [SupermuxHarnessControlResponseSubtype.success, .error])
    func decodesControlResponses(_ subtype: SupermuxHarnessControlResponseSubtype) throws {
        let line = #"{"type":"control_response","response":{"subtype":"\#(subtype.rawValue)","request_id":"request","response":{"value":9,"error":"failed"}},"future":true}"#
        let decoded = try decoder.decodeLine(line)
        guard case .controlResponse(let frame) = decoded.frame else {
            Issue.record("Expected control response")
            return
        }
        #expect(frame.subtype == subtype)
        #expect(frame.requestID == "request")
        #expect(frame.response?.integer(forKey: "value") == 9)
        #expect(frame.rawObject.bool(forKey: "future") == true)
    }

    @Test func decodesKeepAlive() throws {
        let decoded = try decoder.decodeLine(#"{"type":"keep_alive","future":"kept"}"#)
        guard case .keepAlive(let frame) = decoded.frame else {
            Issue.record("Expected keep-alive frame")
            return
        }
        #expect(frame.rawObject.string(forKey: "future") == "kept")
        #expect(decoded.frame?.rawObject == decoded.object)
    }

    @Test func everyRichSessionFixtureLineDecodesAndIsRecognized() throws {
        let lines = try fixtureLines(named: "rich-session", extension: "jsonl")
        #expect(lines.count == 202)
        var counts: [String: Int] = [:]
        for line in lines {
            let decoded = try decoder.decodeLine(line)
            let frame = try #require(decoded.frame)
            counts[frameCategory(frame), default: 0] += 1
            #expect(frame.rawObject == decoded.object)
        }
        #expect(counts == [
            "assistant": 19,
            "controlRequest": 1,
            "controlResponse": 1,
            "result": 3,
            "streamEvent": 139,
            "system": 29,
            "user": 10,
        ])
    }

    @Test(arguments: [
        ("ctl_log", 81),
        ("perm_log", 13),
        ("plan_log", 11),
        ("int_log", 6),
    ])
    func everyIncomingProbeFrameDecodesAndIsRecognized(_ fixture: String, _ expectedCount: Int) throws {
        let incoming = try fixtureTranscriptLines(named: fixture, extension: "txt")
            .filter { $0.direction == "<<" }
        #expect(incoming.count == expectedCount)
        for entry in incoming {
            let decoded = try decoder.decodeLine(entry.json)
            #expect(decoded.frame != nil)
        }
    }

    private func fixtureLines(named name: String, extension fileExtension: String) throws -> [String] {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: fileExtension
        ))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func fixtureTranscriptLines(
        named name: String,
        extension fileExtension: String
    ) throws -> [(direction: String, json: String)] {
        try fixtureLines(named: name, extension: fileExtension).compactMap { line in
            guard line.count > 3 else { return nil }
            let direction = String(line.prefix(2))
            guard direction == "<<" || direction == ">>" else { return nil }
            return (direction, String(line.dropFirst(3)))
        }
    }

    private func frameCategory(_ frame: SupermuxHarnessFrame) -> String {
        switch frame {
        case .system: "system"
        case .streamEvent: "streamEvent"
        case .assistant: "assistant"
        case .user: "user"
        case .result: "result"
        case .controlRequest: "controlRequest"
        case .controlResponse: "controlResponse"
        case .controlCancelRequest: "controlCancelRequest"
        case .keepAlive: "keepAlive"
        }
    }
}

import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// The Claude harness request layer's exact wire shapes, and the event
/// decoding that carries transcript frames.
@MainActor
@Suite struct SupermuxClaudeWireTests {
    @Test func sessionsListSendsTheContractMethodWithNoParams() {
        let request = SupermuxClaudeSessionsListRequest()
        #expect(request.wireMethod == "mobile.supermux.claude.sessions.list")
        #expect(request.wireParams.isEmpty)
    }

    @Test func sessionReferenceMethodsSendOnlySessionID() {
        #expect(
            SupermuxClaudeSessionGetRequest(sessionID: "s1").wireMethod
                == "mobile.supermux.claude.session.get"
        )
        #expect(
            SupermuxClaudeSessionResumeRequest(sessionID: "s1").wireMethod
                == "mobile.supermux.claude.session.resume"
        )
        #expect(
            SupermuxClaudeSessionEndRequest(sessionID: "s1").wireMethod
                == "mobile.supermux.claude.session.end"
        )
        #expect(
            SupermuxClaudeSessionDeleteRequest(sessionID: "s1").wireMethod
                == "mobile.supermux.claude.session.delete"
        )
        #expect(
            SupermuxClaudeInterruptRequest(sessionID: "s1").wireMethod
                == "mobile.supermux.claude.interrupt"
        )
        let params = SupermuxClaudeSessionGetRequest(sessionID: "s1").wireParams
        #expect(params as NSDictionary == ["session_id": "s1"] as NSDictionary)
    }

    /// Resume must NOT carry a launcher: the Mac reuses the persisted one, so
    /// a ccx session can never silently come back as plain Claude.
    @Test func resumeCarriesNoLauncher() {
        let params = SupermuxClaudeSessionResumeRequest(sessionID: "s1").wireParams
        #expect(params["launcher"] == nil)
        #expect(params.count == 1)
    }

    @Test func createEncodesEveryContractKeyInSnakeCase() throws {
        let request = SupermuxClaudeSessionCreateRequest(
            body: SupermuxClaudeSessionCreateRequestDTO(
                cwd: "/repo",
                projectID: "p1",
                launcher: .custom(path: "/opt/bin/claude"),
                model: "opus",
                effort: "high",
                fastMode: true,
                thinkingBudget: 4096,
                initialPrompt: "hello"
            )
        )
        #expect(request.wireMethod == "mobile.supermux.claude.session.create")
        let params = request.wireParams
        #expect(params["cwd"] as? String == "/repo")
        #expect(params["project_id"] as? String == "p1")
        #expect(params["model"] as? String == "opus")
        #expect(params["effort"] as? String == "high")
        #expect(params["fast_mode"] as? Bool == true)
        #expect(params["thinking_budget"] as? Int == 4096)
        #expect(params["initial_prompt"] as? String == "hello")
        let launcher = try #require(params["launcher"] as? [String: Any])
        #expect(launcher["custom"] as? String == "/opt/bin/claude")
    }

    /// Absent optionals are OMITTED, never sent as nulls or defaults — the
    /// Mac handlers distinguish "not set" from "set to nothing".
    @Test func createOmitsUnsetOptionals() {
        let params = SupermuxClaudeSessionCreateRequest(
            body: SupermuxClaudeSessionCreateRequestDTO(cwd: "/repo", launcher: .ccx)
        ).wireParams
        #expect(params["model"] == nil)
        #expect(params["effort"] == nil)
        #expect(params["thinking_budget"] == nil)
        #expect(params["initial_prompt"] == nil)
        #expect(params["project_id"] == nil)
        #expect(params["launcher"] as? String == "ccx")
    }

    @Test func historyOmitsTheCursorOnTheNewestPage() {
        let newest = SupermuxClaudeHistoryRequest(
            body: SupermuxClaudeHistoryRequestDTO(sessionID: "s1", limit: 100)
        )
        #expect(newest.wireMethod == "mobile.supermux.claude.history")
        #expect(newest.wireParams["before_seq"] == nil)
        #expect(newest.wireParams["limit"] as? Int == 100)

        let older = SupermuxClaudeHistoryRequest(
            body: SupermuxClaudeHistoryRequestDTO(sessionID: "s1", beforeSeq: 42, limit: 100)
        )
        #expect(older.wireParams["before_seq"] as? UInt64 == 42)
    }

    @Test func setOptionEncodesEachScalarValueShape() {
        func value(for option: SupermuxClaudeOption, _ scalar: SupermuxClaudeOptionValue) -> [String: Any] {
            SupermuxClaudeSetOptionRequest(
                body: SupermuxClaudeSetOptionRequestDTO(sessionID: "s1", option: option, value: scalar)
            ).wireParams
        }
        #expect(value(for: .model, .string("opus"))["option"] as? String == "model")
        #expect(value(for: .fastMode, .bool(true))["option"] as? String == "fast_mode")
        #expect(value(for: .fastMode, .bool(true))["value"] as? Bool == true)
        #expect(value(for: .thinkingBudget, .integer(8192))["value"] as? Int == 8192)
        #expect(value(for: .effort, .string("low"))["value"] as? String == "low")
    }

    @Test func watchCarriesTheDeviceClientID() {
        let request = SupermuxClaudeWatchRequest(enable: true, clientID: "device-1")
        #expect(request.wireMethod == "mobile.supermux.claude.watch")
        #expect(request.wireParams as NSDictionary == ["enable": true, "client_id": "device-1"] as NSDictionary)
    }

    @Test func toolPayloadOmitsAZeroOffsetOnlyWhenUnset() {
        let first = SupermuxClaudeToolPayloadRequest(
            body: SupermuxClaudeToolPayloadRequestDTO(sessionID: "s1", messageID: "m1")
        )
        #expect(first.wireMethod == "mobile.supermux.claude.tool_payload")
        #expect(first.wireParams["offset"] == nil)
        let resumed = SupermuxClaudeToolPayloadRequest(
            body: SupermuxClaudeToolPayloadRequestDTO(sessionID: "s1", messageID: "m1", offset: 1024)
        )
        #expect(resumed.wireParams["offset"] as? Int64 == 1024)
    }

    @Test func optionsOmitsTheSessionWhenAskedGlobally() {
        #expect(SupermuxClaudeOptionsRequest().wireParams.isEmpty)
        #expect(SupermuxClaudeOptionsRequest(sessionID: "s1").wireParams["session_id"] as? String == "s1")
    }

    // MARK: Event decoding

    @Test func claudeEventDecodesItsTranscriptFrame() throws {
        let payload = Data(#"""
        {"session_id":"s1","event_no":7,"frame":{"kind":"append","messages":[
        {"id":"m1","seq":3,"role":"assistant","timestamp":1,"kind":"prose","text":"hi"}]}}
        """#.utf8)
        let event = try #require(
            SupermuxMobileEvent(topic: "supermux.claude.event", payloadJSON: payload)
        )
        let frame = try #require(event.claudeFrame)
        #expect(frame.sessionID == "s1")
        #expect(frame.eventNo == 7)
        #expect(frame.frame == .append([
            SupermuxClaudeChatMessageDTO(
                id: "m1",
                seq: 3,
                role: .assistant,
                timestamp: 1,
                kind: .prose,
                text: "hi"
            ),
        ]))
    }

    /// A malformed payload must NOT be dropped as "not our topic": it decodes
    /// to a frameless claude event, which the conversation store treats as a
    /// gap and repairs from history.
    @Test func malformedClaudeEventKeepsTheTopicButLosesTheFrame() throws {
        let event = try #require(
            SupermuxMobileEvent(topic: "supermux.claude.event", payloadJSON: Data("{}".utf8))
        )
        #expect(event.topic == .claudeEvent)
        #expect(event.claudeFrame == nil)
    }

    @Test func pokeTopicsStillDecodeTheirWorkspacePayload() throws {
        let event = try #require(SupermuxMobileEvent(
            topic: "supermux.changes.updated",
            payloadJSON: Data(#"{"workspace_id":"w1"}"#.utf8)
        ))
        #expect(event.workspaceID == "w1")
        #expect(event.claudeFrame == nil)
    }

    @Test func sessionsUpdatedIsAPayloadLightPoke() throws {
        let event = try #require(
            SupermuxMobileEvent(topic: "supermux.claude.sessions_updated", payloadJSON: nil)
        )
        #expect(event.topic == .claudeSessionsUpdated)
        #expect(event.claudeFrame == nil)
    }

    @Test func theHarnessCapabilityGatesTheWholeSurface() {
        let without = SupermuxMobileCapabilities(hostCapabilities: ["supermux.projects.v1"])
        #expect(!without.supportsClaudeHarness)
        let with = SupermuxMobileCapabilities(hostCapabilities: ["supermux.claude.v1"])
        #expect(with.supportsClaudeHarness)
    }
}

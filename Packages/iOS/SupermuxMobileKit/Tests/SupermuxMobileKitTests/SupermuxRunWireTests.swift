import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// Wire coding for the run/launch/action namespace: the typed requests own
/// the exact §2 wire shapes, and the responses decode the committed m4-f1
/// result payloads (unknown fields tolerated).
@Suite struct SupermuxRunWireTests {
    // MARK: Requests

    @Test func runStateRequestShape() {
        let request = SupermuxRunStateRequest()
        #expect(request.wireMethod == "mobile.supermux.run.state")
        #expect(request.wireParams.isEmpty)
    }

    @Test func runStartRequestOmitsAbsentCommandID() {
        let request = SupermuxRunStartRequest(projectID: "p-1", commandID: nil)
        #expect(request.wireMethod == "mobile.supermux.run.start")
        #expect(request.wireParams as NSDictionary == ["project_id": "p-1"] as NSDictionary)
    }

    @Test func runStartRequestCarriesTheZeroBasedCommandID() {
        let request = SupermuxRunStartRequest(projectID: "p-1", commandID: 0)
        #expect(request.wireParams as NSDictionary == [
            "project_id": "p-1",
            "command_id": 0,
        ] as NSDictionary)
    }

    @Test func runStopRequestShape() {
        let request = SupermuxRunStopRequest(projectID: "p-1")
        #expect(request.wireMethod == "mobile.supermux.run.stop")
        #expect(request.wireParams as NSDictionary == ["project_id": "p-1"] as NSDictionary)
    }

    @Test func presetLaunchRequestTargetsExactlyOneOfProjectOrWorkspace() {
        let projectTargeted = SupermuxPresetLaunchRequest(presetID: "pr-1", target: .project(id: "p-1"))
        #expect(projectTargeted.wireMethod == "mobile.supermux.preset.launch")
        #expect(projectTargeted.wireParams as NSDictionary == [
            "preset_id": "pr-1",
            "project_id": "p-1",
        ] as NSDictionary)

        let workspaceTargeted = SupermuxPresetLaunchRequest(presetID: "pr-1", target: .workspace(id: "w-1"))
        #expect(workspaceTargeted.wireParams as NSDictionary == [
            "preset_id": "pr-1",
            "workspace_id": "w-1",
        ] as NSDictionary)
    }

    @Test func actionRunRequestShape() {
        let request = SupermuxActionRunRequest(projectID: "p-1", actionID: "a-1")
        #expect(request.wireMethod == "mobile.supermux.action.run")
        #expect(request.wireParams as NSDictionary == [
            "project_id": "p-1",
            "action_id": "a-1",
        ] as NSDictionary)
    }

    // MARK: Responses

    @Test func runStateResponseDecodesTheRunsArrayWithUnknownFields() throws {
        let json = Data("""
        {
          "runs": [
            {
              "project_id": "p-1",
              "is_running": true,
              "command": "sleep 60",
              "workspace_id": "w-1",
              "started_at": 1770000000.0,
              "future_field": "ignored"
            },
            {"project_id": "p-2", "is_running": false}
          ],
          "future_top_level": 1
        }
        """.utf8)
        let response = try JSONDecoder().decode(SupermuxRunStateResponse.self, from: json)
        #expect(response.runs.count == 2)
        #expect(response.runs[0].isRunning == true)
        #expect(response.runs[0].command == "sleep 60")
        #expect(response.runs[0].startedAt == 1_770_000_000.0)
        #expect(response.runs[1].isRunning == false)
    }

    @Test func runWriteResponseDecodesTheSingleRunRow() throws {
        let json = Data("""
        {"run": {"project_id": "p-1", "is_running": true, "command": "npm run dev"}}
        """.utf8)
        let response = try JSONDecoder().decode(SupermuxRunWriteResponse.self, from: json)
        #expect(response.run.projectId == "p-1")
        #expect(response.run.isRunning == true)
    }

    @Test func presetLaunchResponseDecodesTheSnakeCaseTargetIDs() throws {
        let json = Data("""
        {"workspace_id": "w-1", "terminal_id": "t-1", "future": true}
        """.utf8)
        let response = try JSONDecoder().decode(SupermuxPresetLaunchResponse.self, from: json)
        #expect(response.workspaceId == "w-1")
        #expect(response.terminalId == "t-1")
    }

    @Test func actionRunResponseDecodesBothCommittedShapes() throws {
        let openURL = try JSONDecoder().decode(
            SupermuxActionRunResponse.self,
            from: Data(#"{"kind": "open_url", "url": "https://example.com/dashboard"}"#.utf8)
        )
        #expect(openURL.opensURLLocally)
        #expect(openURL.url == "https://example.com/dashboard")

        let command = try JSONDecoder().decode(
            SupermuxActionRunResponse.self,
            from: Data(#"{"ok": true, "kind": "command"}"#.utf8)
        )
        #expect(command.opensURLLocally == false)
        #expect(command.ok == true)
    }

    @Test func actionRunResponseWithoutAURLNeverOpensLocally() throws {
        let malformed = try JSONDecoder().decode(
            SupermuxActionRunResponse.self,
            from: Data(#"{"kind": "open_url"}"#.utf8)
        )
        #expect(malformed.opensURLLocally == false)
    }
}

import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// The `mobile.supermux.agent.*` request values own the exact wire shape.
struct SupermuxAgentWireTests {
    @Test func methodStringsMatchTheContract() {
        #expect(SupermuxAgentOptionsRequest().wireMethod == "mobile.supermux.agent.options")
        #expect(SupermuxAgentStartRequest(projectID: "p", prompt: "x").wireMethod == "mobile.supermux.agent.start")
    }

    @Test func optionsParamsOmitAbsentValues() {
        #expect(SupermuxAgentOptionsRequest().wireParams as NSDictionary == [:] as NSDictionary)
        let full = SupermuxAgentOptionsRequest(projectID: "p", command: "ccx", refresh: true)
        #expect(full.wireParams as NSDictionary == ["project_id": "p", "command": "ccx", "refresh": true] as NSDictionary)
    }

    @Test func startParamsOmitAbsentValues() {
        let minimal = SupermuxAgentStartRequest(projectID: "p", prompt: "fix it")
        #expect(minimal.wireParams as NSDictionary == ["project_id": "p", "prompt": "fix it"] as NSDictionary)
        let full = SupermuxAgentStartRequest(
            projectID: "p", prompt: "fix it", command: "cc", model: "opus", effort: "high", baseBranch: "main",
            workspaceName: "Fix It", branchName: "fix-it"
        )
        #expect(full.wireParams as NSDictionary == [
            "project_id": "p", "prompt": "fix it", "command": "cc",
            "model": "opus", "effort": "high", "base_branch": "main",
            "workspace_name": "Fix It", "branch_name": "fix-it",
        ] as NSDictionary)
    }

    @Test func startResponseDecodesLeniently() throws {
        let json = #"{"workspace_id":"w1","workspace_name":"Fix Login","branch_name":"fix-login","named_by_ai":true}"#
        let response = try JSONDecoder().decode(SupermuxAgentStartResponse.self, from: Data(json.utf8))
        #expect(response.workspaceId == "w1")
        #expect(response.workspaceName == "Fix Login")
        #expect(response.branchName == "fix-login")
        #expect(response.namedByAI == true)
        #expect(response.worktree == nil)
        #expect(try JSONDecoder().decode(SupermuxAgentStartResponse.self, from: Data("{}".utf8)) == SupermuxAgentStartResponse())
    }
}

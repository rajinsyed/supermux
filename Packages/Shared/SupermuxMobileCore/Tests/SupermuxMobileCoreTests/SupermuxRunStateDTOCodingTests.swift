import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxRunStateDTOCodingTests {
    private let coding = WireCodingTestSupport()

    private var fullState: SupermuxRunStateDTO {
        SupermuxRunStateDTO(
            projectId: "p-1",
            isRunning: true,
            command: "bun dev",
            workspaceId: "workspace:3",
            startedAt: 1_900_000_000
        )
    }

    @Test func runStateRoundTrips() throws {
        #expect(try coding.roundTrip(fullState) == fullState)
    }

    @Test func runStateEncodesSnakeCaseKeys() throws {
        let keys = try coding.encodedKeys(of: fullState)
        #expect(keys == ["project_id", "is_running", "command", "workspace_id", "started_at"])
    }

    @Test func runStateDecodesWithOnlyEssentialFields() throws {
        let state = try coding.decode(SupermuxRunStateDTO.self, from: #"{"project_id": "p-9"}"#)
        #expect(state.projectId == "p-9")
        #expect(state.isRunning == nil)
        #expect(state.command == nil)
    }

    @Test func runStateUnknownFieldTolerance() throws {
        let json = """
        {"project_id": "p-1", "is_running": false, "exit_code": 0, "logs_tail": ["done"]}
        """
        let state = try coding.decode(SupermuxRunStateDTO.self, from: json)
        #expect(state.projectId == "p-1")
        #expect(state.isRunning == false)
    }
}

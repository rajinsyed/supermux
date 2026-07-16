import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// Wire-payload tests for the `mobile.supermux.run.*` read path (validation
/// contract RPC-RUN-01, decomposed): a fixture project with a harmless
/// long-running run command (`sleep 60`) transitions through
/// start → running-with-command → stop exactly as the
/// ``SupermuxMobileRunPayloadBuilder`` projects it onto the
/// `SupermuxRunStateDTO` wire shape.
///
/// The GUI half (the coordinator launching the command in a real terminal
/// surface) cannot run in a windowless test — the builder consumes the
/// coordinator's value-typed ``SupermuxMobileRunSnapshot`` projection, which
/// is the documented test seam.
struct SupermuxMobileRunPayloadTests {
    private let builder = SupermuxMobileRunPayloadBuilder()

    // MARK: - RPC-RUN-01 (state transitions through the projection seam)

    @Test func sleepFixtureTransitionsThroughStartAndStop() throws {
        let project = SupermuxProject(
            name: "Fixture",
            rootPath: "/tmp/supermux-run-fixture",
            runCommands: ["sleep 60"]
        )
        let workspaceId = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)

        // Before run.start: one row per project, not running, no command.
        let idle = try builder.runState(projects: [project], snapshots: [])
        let idleRuns = try #require(idle["runs"] as? [[String: Any]])
        try #require(idleRuns.count == 1)
        #expect(idleRuns[0]["project_id"] as? String == project.id.uuidString)
        #expect(idleRuns[0]["is_running"] as? Bool == false)
        #expect(idleRuns[0]["command"] == nil)
        #expect(idleRuns[0]["started_at"] == nil)

        // After run.start: running with the sleep command and start time.
        let snapshot = SupermuxMobileRunSnapshot(
            projectId: project.id,
            workspaceId: workspaceId,
            command: "sleep 60",
            startedAt: startedAt
        )
        let running = try builder.runState(projects: [project], snapshots: [snapshot])
        let runningRuns = try #require(running["runs"] as? [[String: Any]])
        let dto = try SupermuxWireJSON().decode(SupermuxRunStateDTO.self, from: runningRuns[0])
        #expect(dto == SupermuxRunStateDTO(
            projectId: project.id.uuidString,
            isRunning: true,
            command: "sleep 60",
            workspaceId: workspaceId.uuidString,
            startedAt: startedAt.timeIntervalSince1970
        ))

        // After run.stop: back to not running.
        let stopped = try builder.runState(projects: [project], snapshots: [])
        let stoppedRuns = try #require(stopped["runs"] as? [[String: Any]])
        #expect(stoppedRuns[0]["is_running"] as? Bool == false)
        #expect(stoppedRuns[0]["command"] == nil)
    }

    @Test func runStateCoversEveryProjectInOrder() throws {
        let running = SupermuxProject(name: "A", rootPath: "/tmp/a", runCommands: ["sleep 5"])
        let idle = SupermuxProject(name: "B", rootPath: "/tmp/b")
        let snapshot = SupermuxMobileRunSnapshot(
            projectId: running.id,
            workspaceId: UUID(),
            command: "sleep 5",
            startedAt: Date()
        )
        let payload = try builder.runState(projects: [running, idle], snapshots: [snapshot])
        let runs = try #require(payload["runs"] as? [[String: Any]])
        try #require(runs.count == 2)
        #expect(runs[0]["project_id"] as? String == running.id.uuidString)
        #expect(runs[0]["is_running"] as? Bool == true)
        #expect(runs[1]["project_id"] as? String == idle.id.uuidString)
        #expect(runs[1]["is_running"] as? Bool == false)
    }

    @Test func projectlessSnapshotsAreNotAttributedToAnyProject() throws {
        let project = SupermuxProject(name: "A", rootPath: "/tmp/a")
        let orphan = SupermuxMobileRunSnapshot(
            projectId: nil,
            workspaceId: UUID(),
            command: "sleep 5",
            startedAt: Date()
        )
        let payload = try builder.runState(projects: [project], snapshots: [orphan])
        let runs = try #require(payload["runs"] as? [[String: Any]])
        #expect(runs[0]["is_running"] as? Bool == false)
    }

    @Test func oldestRunRepresentsAProjectWithTwoRunningWorkspaces() throws {
        let project = SupermuxProject(name: "A", rootPath: "/tmp/a")
        let older = SupermuxMobileRunSnapshot(
            projectId: project.id,
            workspaceId: UUID(),
            command: "sleep 5",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = SupermuxMobileRunSnapshot(
            projectId: project.id,
            workspaceId: UUID(),
            command: "sleep 9",
            startedAt: Date(timeIntervalSince1970: 200)
        )
        let payload = try builder.runPayload(projectId: project.id, snapshot: [newer, older].first {
            $0.startedAt.timeIntervalSince1970 == 100
        })
        let run = try #require(payload["run"] as? [String: Any])
        #expect(run["command"] as? String == "sleep 5")

        // The state projection picks the oldest run on its own.
        let state = try builder.runState(projects: [project], snapshots: [newer, older])
        let runs = try #require(state["runs"] as? [[String: Any]])
        #expect(runs[0]["workspace_id"] as? String == older.workspaceId.uuidString)
    }

    @Test func runPayloadWithoutASnapshotReportsNotRunning() throws {
        let projectId = UUID()
        let payload = try builder.runPayload(projectId: projectId, snapshot: nil)
        let run = try #require(payload["run"] as? [String: Any])
        #expect(run["project_id"] as? String == projectId.uuidString)
        #expect(run["is_running"] as? Bool == false)
        #expect(run["workspace_id"] == nil)
    }

    // MARK: - Run command resolution (desktop ⌘G semantics)

    @Test func joinedMirrorsTheDesktopRunCommandRule() {
        #expect(SupermuxMobileRunCommand.joined(["npm install", "  ", "npm run dev "]) == "npm install && npm run dev")
        #expect(SupermuxMobileRunCommand.joined([]) == "")
        #expect(SupermuxMobileRunCommand.joined(["   "]) == "")
    }

    @Test func selectedPicksOneRunCommandByIndex() {
        let commands = ["npm run dev", " ", "sleep 60 "]
        #expect(SupermuxMobileRunCommand.selected(commands: commands, index: 0) == "npm run dev")
        #expect(SupermuxMobileRunCommand.selected(commands: commands, index: 2) == "sleep 60")
        #expect(SupermuxMobileRunCommand.selected(commands: commands, index: 1) == nil)
        #expect(SupermuxMobileRunCommand.selected(commands: commands, index: 3) == nil)
        #expect(SupermuxMobileRunCommand.selected(commands: commands, index: -1) == nil)
    }
}

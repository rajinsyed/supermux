import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// One other Mac's project state, as ``SupermuxRemoteProjectsModel`` holds it:
/// its `projects.list` projects (live, or from the offline cache) and terminal
/// presets, `run.state`, and the worktree lists loaded so far. The sidebar and
/// the device-mirror behaviors (⌘G, presets bar) both read this one copy.
///
/// Project ids here are that Mac's ids. Use them only in RPCs to ``machine``.
struct SupermuxDeviceProjects: Identifiable, Equatable {
    let machine: SurfaceMachineID
    var name: String
    var isOnline: Bool
    var isLoopback: Bool
    /// The Mac's projects.
    var projects: [SupermuxProjectDTO]
    /// The Mac's terminal presets (from the same `projects.list`; never cached).
    var presets: [SupermuxTerminalPresetDTO]
    /// Whether ``projects`` came from the offline cache and has not been
    /// refreshed on this connection.
    var isFromCache: Bool
    /// Whether the Mac serves `supermux.projects.v1`; `nil` until asked.
    var supportsProjects: Bool?
    /// The Mac's run states, one per project (`run.state`'s `runs`).
    var runs: [SupermuxRunStateDTO]
    /// The Mac's live runs, one per running workspace (`run.state`'s
    /// `workspace_runs`); `nil` from a Mac that sends only ``runs``.
    var workspaceRuns: [SupermuxRunStateDTO]?
    /// Worktree lists loaded so far, keyed by that Mac's project id.
    var worktreesByProjectID: [UUID: [SupermuxWorktreeDTO]]
    /// The last refresh failure, if the latest refresh failed.
    var lastError: String?

    var id: String { machine.rawValue }

    /// The Mac as the project UI describes it.
    var device: SupermuxProjectDevice {
        SupermuxProjectDevice(machineID: machine.rawValue, name: name, isOnline: isOnline)
    }

    /// An entry with nothing loaded yet.
    static func empty(for device: SupermuxDevice) -> SupermuxDeviceProjects {
        SupermuxDeviceProjects(
            machine: device.machine,
            name: device.displayName,
            isOnline: device.isConnected,
            isLoopback: device.isLoopback,
            projects: [],
            presets: [],
            isFromCache: false,
            supportsProjects: nil,
            runs: [],
            workspaceRuns: nil,
            worktreesByProjectID: [:],
            lastError: nil
        )
    }

    /// The Mac's project with this id.
    func project(id: UUID) -> SupermuxProjectDTO? {
        projects.first { UUID(uuidString: $0.id) == id }
    }

    /// Whether the Mac runs the project's run command now.
    func isRunning(projectID: UUID) -> Bool {
        runs.contains { UUID(uuidString: $0.projectId) == projectID && $0.isRunning == true }
    }

    /// Whether a run command runs in that Mac's workspace `remoteWorkspaceID`.
    func isRunning(remoteWorkspaceID: String) -> Bool {
        runsByWorkspace.contains { $0.isRunning == true && Self.runs($0, in: remoteWorkspaceID) }
    }

    /// Whether project `projectID`'s run command runs in that Mac's workspace
    /// `remoteWorkspaceID` (a mirror's Run button).
    func isRunning(projectID: String, remoteWorkspaceID: String) -> Bool {
        runsByWorkspace.contains { run in
            run.isRunning == true
                && run.projectId.caseInsensitiveCompare(projectID) == .orderedSame
                && Self.runs(run, in: remoteWorkspaceID)
        }
    }

    /// The `run.state` result.
    struct RunState: Decodable {
        let runs: [SupermuxRunStateDTO]
        let workspaceRuns: [SupermuxRunStateDTO]?

        /// Nothing runs (a Mac without the run capability).
        static let none = RunState(runs: [], workspaceRuns: nil)

        private enum CodingKeys: String, CodingKey {
            case runs
            case workspaceRuns = "workspace_runs"
        }
    }

    /// Replaces the Mac's run states with a fresh `run.state`.
    mutating func setRuns(_ state: RunState) {
        runs = state.runs
        workspaceRuns = state.workspaceRuns
    }

    /// Folds in a `run.start` / `run.stop` reply for that Mac's workspace
    /// `remoteWorkspaceID` before the next `run.state` lands. Only that
    /// workspace's run changes (the project may still run elsewhere there);
    /// the per-project rows follow with that refresh.
    mutating func apply(run: SupermuxRunStateDTO, remoteWorkspaceID: String) {
        guard workspaceRuns != nil else {
            // A Mac without per-workspace runs: its one row per project.
            runs.removeAll { $0.projectId.caseInsensitiveCompare(run.projectId) == .orderedSame }
            runs.append(run)
            return
        }
        workspaceRuns?.removeAll { Self.runs($0, in: remoteWorkspaceID) }
        if run.isRunning == true { workspaceRuns?.append(run) }
    }

    /// Rows that name their workspace: every live run when the Mac sends
    /// them, else its one (oldest) run per project.
    private var runsByWorkspace: [SupermuxRunStateDTO] { workspaceRuns ?? runs }

    private static func runs(_ run: SupermuxRunStateDTO, in remoteWorkspaceID: String) -> Bool {
        run.workspaceId.map(SupermuxRemoteWorkspaceRef.canonicalWorkspaceID)
            == SupermuxRemoteWorkspaceRef.canonicalWorkspaceID(remoteWorkspaceID)
    }
}

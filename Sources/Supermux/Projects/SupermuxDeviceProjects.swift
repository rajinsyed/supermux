import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// One other Mac's project state, as ``SupermuxRemoteProjectsModel`` holds it:
/// its `projects.list` (live, or from the offline cache), `run.state`, and the
/// worktree lists loaded so far.
///
/// Project ids here are that Mac's ids. Use them only in RPCs to ``machine``.
struct SupermuxDeviceProjects: Identifiable, Equatable {
    let machine: SurfaceMachineID
    var name: String
    var isOnline: Bool
    var isLoopback: Bool
    /// The Mac's projects.
    var projects: [SupermuxProjectDTO]
    /// Whether ``projects`` came from the offline cache and has not been
    /// refreshed on this connection.
    var isFromCache: Bool
    /// Whether the Mac serves `supermux.projects.v1`; `nil` until asked.
    var supportsProjects: Bool?
    /// The Mac's run states (`run.state`).
    var runs: [SupermuxRunStateDTO]
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
            isFromCache: false,
            supportsProjects: nil,
            runs: [],
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
        let wanted = SupermuxRemoteWorkspaceRef.canonicalWorkspaceID(remoteWorkspaceID)
        return runs.contains { run in
            run.isRunning == true
                && run.workspaceId.map(SupermuxRemoteWorkspaceRef.canonicalWorkspaceID) == wanted
        }
    }
}

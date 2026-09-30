import AppKit
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// ⌘G and the presets bar's Run / Stop inside a device mirror: the run
/// starts and stops ON THE MAC THAT OWNS THE WORKSPACE, for that Mac's
/// project (`supermux_project_id` of the remote record), via
/// `mobile.supermux.run.start` / `run.stop` with the remote workspace id — the
/// same host path the iPhone uses. The state shown is that Mac's `run.state`,
/// as ``SupermuxRemoteProjectsModel`` (the one per-Mac state) holds it.
///
/// ``SupermuxRunCoordinator`` asks this controller first; `nil` answers mean
/// "not a mirror", and the coordinator's local path runs unchanged.
@MainActor
final class SupermuxMirrorRunController {
    private let resolver: SupermuxMirrorResolver
    private let remoteProjects: SupermuxRemoteProjectsModel
    private let devices: SupermuxDevices
    private var inFlight: Set<SupermuxRemoteWorkspaceRef> = []

    init(resolver: SupermuxMirrorResolver, remoteProjects: SupermuxRemoteProjectsModel, devices: SupermuxDevices) {
        self.resolver = resolver
        self.remoteProjects = remoteProjects
        self.devices = devices
    }

    /// The owning Mac's run state for a mirror, or `nil` for a local workspace.
    /// Read-only (safe in view bodies).
    func isRunning(workspaceId: UUID) -> Bool? {
        guard let target = resolver.target(forWorkspaceID: workspaceId) else { return nil }
        return isRunning(target)
    }

    private func isRunning(_ target: SupermuxMirrorTarget) -> Bool {
        guard let projectID = target.remoteProjectID else { return false }
        return remoteProjects.device(target.machine)?
            .isRunning(projectID: projectID, remoteWorkspaceID: target.ref.workspaceID) ?? false
    }

    /// Toggles the run for a mirror, or returns `nil` for a local workspace.
    ///
    /// - Parameters:
    ///   - workspace: The workspace ⌘G or the Run button targets.
    ///   - explainsMissingProject: Present an alert when the remote workspace
    ///     belongs to no project (the Run button). ⌘G passes `false` so the
    ///     shared chord falls through to Find Next, exactly like a local
    ///     workspace outside any project.
    /// - Returns: Whether the event was consumed.
    func toggle(_ workspace: Workspace, explainsMissingProject: Bool) -> Bool? {
        guard let target = resolver.target(for: workspace) else { return nil }
        guard let projectID = target.remoteProjectID else {
            if explainsMissingProject { SupermuxMirrorAlerts.presentNoRemoteProject(target) }
            return explainsMissingProject
        }
        guard inFlight.insert(target.ref).inserted else { return true }
        let wasRunning = isRunning(target)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(target.ref) }
            do {
                if wasRunning {
                    try await self.stop(target, projectID: projectID)
                } else {
                    try await self.start(target, projectID: projectID)
                }
            } catch {
                SupermuxMirrorAlerts.presentRunFailure(target, error: error)
            }
        }
        return true
    }

    /// Starts the remote project's run command in the mirrored remote workspace.
    func start(_ target: SupermuxMirrorTarget, projectID: String) async throws {
        let result = try await devices.request(
            .runStart,
            params: ["project_id": projectID, "workspace_id": target.remoteWorkspaceID],
            on: target.machine
        )
        apply(result, on: target)
    }

    /// Stops the remote project's run command in the mirrored remote workspace.
    func stop(_ target: SupermuxMirrorTarget, projectID: String) async throws {
        let result = try await devices.request(
            .runStop,
            params: ["project_id": projectID, "workspace_id": target.remoteWorkspaceID],
            on: target.machine
        )
        apply(result, on: target)
    }

    private func apply(_ result: [String: Any], on target: SupermuxMirrorTarget) {
        if let object = result["run"] as? [String: Any],
           let run = try? SupermuxWireJSON().decode(SupermuxRunStateDTO.self, from: object) {
            remoteProjects.apply(run: run, on: target.machine, remoteWorkspaceID: target.ref.workspaceID)
        }
        Task { @MainActor [remoteProjects] in await remoteProjects.refreshRuns(target.machine) }
    }
}

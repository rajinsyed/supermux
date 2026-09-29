import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Builds the Projects section's other-Mac presentation for one window from
/// the unified list and the remote-projects model: remote-only rows, device
/// extras for local rows, and the window's remote actions. Reads observable
/// state, so the calling body re-renders when any of it changes.
@MainActor
enum SupermuxRemoteProjectsPresenter {
    static func presentation(for tabManager: TabManager) -> SupermuxRemoteProjectsPresentation {
        let list = SupermuxComposition.unifiedProjects.list
        let remote = SupermuxComposition.remoteProjects
        let setUpDevices = remote.devices
            .filter { $0.isOnline && !$0.isLoopback && $0.supportsProjects == true }
            .map(\.device)
        var rows: [SupermuxRemoteProjectRow] = []
        var extras: [UUID: SupermuxProjectRemoteExtras] = [:]
        for project in list.projects {
            let worktrees = remoteWorktrees(of: project, remote: remote)
            var targets = project.devicesLacking(among: setUpDevices).map(SupermuxProjectSetupDestination.device)
            let remoteURL = repositoryURL(of: project, remote: remote)
            if let localID = project.localProjectID {
                guard !project.remoteLocations.isEmpty || !targets.isEmpty else { continue }
                extras[localID] = SupermuxProjectRemoteExtras(
                    project: project,
                    worktrees: worktrees,
                    setUpTargets: targets,
                    remoteURL: remoteURL
                )
            } else if let location = project.locations.first, let machineID = location.machineID {
                targets.insert(.thisMac, at: 0)
                let machine = SurfaceMachineID(rawValue: machineID)
                let state = remote.device(machine)
                rows.append(SupermuxRemoteProjectRow(
                    project: project,
                    avatar: SupermuxProject(
                        id: project.id,
                        name: project.name,
                        rootPath: location.rootPath,
                        colorHex: project.colorHex,
                        iconSymbol: project.iconSymbol,
                        createdAt: Date(timeIntervalSince1970: 0)
                    ),
                    icon: remote.icon(machine: machine, projectID: location.projectID),
                    location: location,
                    actions: state?.project(id: location.projectID)?.actions ?? [],
                    isRunning: state?.isRunning(projectID: location.projectID) ?? false,
                    worktrees: worktrees,
                    setUpTargets: targets,
                    remoteURL: remoteURL
                ))
            }
        }
        return SupermuxRemoteProjectsPresentation(
            rows: rows,
            extrasByLocalProjectID: extras,
            actions: SupermuxRemoteProjectActionsFactory.actions(for: tabManager),
            deviceAvailability: { deviceAvailability() }
        )
    }

    /// Each device's link state for the New Worktree picker's dots. Reads the
    /// observable device list, so an open sheet re-renders on a link change.
    static func deviceAvailability() -> [String: SupermuxWorktreeDeviceAvailability] {
        Dictionary(
            SupermuxComposition.devices.devices.map { device in
                let availability: SupermuxWorktreeDeviceAvailability = switch device.linkState {
                case .connected: .online
                case .connecting: .connecting
                case .offline: .offline
                }
                return (device.machine.rawValue, availability)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The device copies' worktrees that have no workspace there, or whose
    /// workspace is not mirrored here yet (opening it then mirrors it).
    static func remoteWorktrees(
        of project: SupermuxUnifiedProject,
        remote: SupermuxRemoteProjectsModel
    ) -> [SupermuxRemoteWorktree] {
        let index = SupermuxComposition.deviceWorkspaceIndex
        var result: [SupermuxRemoteWorktree] = []
        for location in project.remoteLocations {
            guard let machineID = location.machineID else { continue }
            let machine = SurfaceMachineID(rawValue: machineID)
            for worktree in remote.device(machine)?.worktreesByProjectID[location.projectID] ?? [] {
                if worktree.isOpen == true, let workspaceID = worktree.workspaceId,
                   index.localWorkspace(showing: SupermuxRemoteWorkspaceRef(machine: machine, workspaceID: workspaceID)) != nil {
                    continue
                }
                result.append(SupermuxRemoteWorktree(
                    location: location,
                    path: worktree.path,
                    branch: worktree.branch,
                    isDirty: worktree.isDirty ?? false,
                    pullRequest: pullRequest(worktree.pullRequest)
                ))
            }
        }
        return result
    }

    /// The repository a clone would use: a device copy's origin, else this
    /// Mac's.
    private static func repositoryURL(
        of project: SupermuxUnifiedProject,
        remote: SupermuxRemoteProjectsModel
    ) -> String? {
        for location in project.remoteLocations {
            guard let machineID = location.machineID,
                  let url = remote.device(SurfaceMachineID(rawValue: machineID))?
                      .project(id: location.projectID)?.gitRemoteURL else { continue }
            return url
        }
        return project.localProjectID.flatMap { SupermuxComposition.projectGitRemotes.url(for: $0) }
    }

    private static func pullRequest(_ dto: SupermuxPullRequestDTO?) -> SupermuxPullRequest? {
        guard let dto, let raw = dto.url, let url = URL(string: raw),
              let state = dto.state, let status = SupermuxPullRequest.Status(rawValue: state) else { return nil }
        return SupermuxPullRequest(number: dto.number, status: status, url: url, title: dto.title, isStale: dto.isStale ?? false)
    }
}

import Foundation
import SupermuxKit

/// App-wide instances for projects across Macs, behind the fork's single
/// sanctioned global (see ``SupermuxComposition``). Each is built once, on
/// first use, with its dependencies injected.
@MainActor
extension SupermuxComposition {
    /// Every other Mac's projects, worktrees and run states (live + offline cache).
    static let remoteProjects = SupermuxRemoteProjectsModel(
        facade: devices,
        cache: SupermuxRemoteProjectsCache()
    )

    /// The merged cross-Mac project list and device-mirror ownership.
    static let unifiedProjects = SupermuxUnifiedProjectsModel(
        projectsModel: projectsModel,
        gitRemotes: projectGitRemotes,
        remoteProjects: remoteProjects,
        devices: devices,
        index: deviceWorkspaceIndex
    )

    /// Folder probe and `git clone` for cross-Mac project setup.
    static let projectSetupService = SupermuxProjectSetupService()

    /// Roots this Mac's user removed, which project sync never re-adds
    /// (shared by every build next to the projects document).
    static let projectSyncSuppression = SupermuxProjectSyncSuppression(
        fileURL: SupermuxPaths.projectSyncSuppressionFileURL
    )

    /// Registers each Mac's projects on the other where the repo already exists.
    static let projectSync = SupermuxProjectSyncCoordinator(
        settings: devicesSettings,
        devices: devices,
        remoteProjects: remoteProjects,
        projectsModel: projectsModel,
        gitRemotes: projectGitRemotes,
        setupService: projectSetupService,
        suppression: projectSyncSuppression
    )
}

/// Launch-time activation for projects across Macs, called from
/// ``SupermuxDevicesGlue/activateIfNeeded()`` (no new upstream hook).
@MainActor
enum SupermuxProjectsGlue {
    private static var isActive = false

    /// Starts the remote-projects model, the unified list and project sync.
    /// Later calls are no-ops.
    static func activateIfNeeded() {
        guard !isActive else { return }
        isActive = true
        SupermuxComposition.remoteProjects.start()
        SupermuxComposition.unifiedProjects.start()
        SupermuxComposition.projectSync.start()
    }
}

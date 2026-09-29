import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// JSON shapes of the projects-across-Macs socket methods (see
/// plans/supermux-remote-workspaces/PROJECTS-API.md). Pure builders.
@MainActor
enum SupermuxProjectsSocketPayloads {
    static func unifiedProject(_ project: SupermuxUnifiedProject) -> [String: Any] {
        [
            "id": project.id.uuidString,
            "name": project.name,
            "is_remote_only": project.isRemoteOnly,
            "git_remote_identity": project.gitRemoteIdentity ?? NSNull(),
            "local_project_id": project.localProjectID?.uuidString ?? NSNull(),
            "locations": project.locations.map(location),
        ]
    }

    static func location(_ location: SupermuxProjectLocation) -> [String: Any] {
        [
            "place": location.isThisMac ? "this_mac" : "device",
            "machine": location.machineID ?? NSNull(),
            "device_name": location.device?.name ?? NSNull(),
            "is_online": location.isOnline,
            "project_id": location.projectID.uuidString,
            "root_path": location.rootPath,
        ]
    }

    static func device(_ device: SupermuxDeviceProjects, icons: Int) -> [String: Any] {
        [
            "machine": device.machine.rawValue,
            "name": device.name,
            "is_online": device.isOnline,
            "is_loopback": device.isLoopback,
            "is_from_cache": device.isFromCache,
            "supports_projects": device.supportsProjects ?? NSNull(),
            "last_error": device.lastError ?? NSNull(),
            "icon_count": icons,
            "projects": device.projects.map { project -> [String: Any] in
                [
                    "id": project.id,
                    "name": project.name,
                    "root_path": project.rootPath,
                    "git_remote_url": project.gitRemoteURL ?? NSNull(),
                    "git_remote_identity": project.gitRemoteIdentity ?? NSNull(),
                    "action_ids": project.actions?.map(\.id) ?? [],
                ]
            },
            "runs": device.runs.map { run -> [String: Any] in
                [
                    "project_id": run.projectId,
                    "is_running": run.isRunning ?? false,
                    "workspace_id": run.workspaceId ?? NSNull(),
                ]
            },
            "worktrees": Dictionary(uniqueKeysWithValues: device.worktreesByProjectID.map { id, list in
                (id.uuidString, list.map(worktree))
            }),
        ]
    }

    static func worktree(_ worktree: SupermuxWorktreeDTO) -> [String: Any] {
        [
            "path": worktree.path,
            "branch": worktree.branch ?? NSNull(),
            "is_open": worktree.isOpen ?? false,
            "workspace_id": worktree.workspaceId ?? NSNull(),
            "is_dirty": worktree.isDirty ?? false,
        ]
    }

    /// Which workspaces of one window nest under which unified project, and
    /// which stay in the flat list (the sidebar's own resolution).
    static func nesting(for tabManager: TabManager) -> [String: Any] {
        let list = SupermuxComposition.unifiedProjects.list
        let ownership = SupermuxMirrorOwnership.current()
        let cache = SupermuxMainListFilter.resolutionCache(for: tabManager)
        let flat = Set(SupermuxMainListFilter.tabsForMainList(tabManager.tabs, tabManager: tabManager).map(\.id))
        let index = SupermuxComposition.deviceWorkspaceIndex
        let workspaces = tabManager.tabs.map { workspace -> [String: Any] in
            let owner = cache.projectId(
                forWorkspace: workspace,
                projects: SupermuxComposition.projectsModel.projects,
                associations: SupermuxComposition.workspaceAssociations,
                ownership: ownership
            )
            let ref = index.ref(forLocal: workspace)
            return [
                "workspace_id": workspace.id.uuidString,
                "title": workspace.title,
                "is_device_mirror": ownership.isMirror(workspace),
                "machine": ref?.machineID ?? NSNull(),
                "remote_workspace_id": ref?.workspaceID ?? NSNull(),
                "project_id": owner?.uuidString ?? NSNull(),
                "project_name": owner.flatMap { list.project(id: $0)?.name } ?? NSNull(),
                "in_flat_list": flat.contains(workspace.id),
            ]
        }
        return [
            "window_id": AppDelegate.shared?.windowId(for: tabManager)?.uuidString ?? NSNull(),
            "workspaces": workspaces,
        ]
    }

    /// The window's sidebar rows as drawn: the Projects section's nested rows
    /// per project in display order (the mount's own builder), and the
    /// directory line of every flat-list row (the flat rows' own snapshot).
    static func sidebarRows(for tabManager: TabManager) -> [String: Any] {
        let unread = TerminalNotificationStore.shared.sidebarUnread
        let rows = SupermuxNestedWorkspaceRows.rows(
            for: tabManager,
            includePullRequest: true,
            unreadCount: { unread.unreadCount(forWorkspaceId: $0) }
        )
        var projectOrder: [UUID] = []
        var rowsByProject: [UUID: [SupermuxOpenWorkspace]] = [:]
        for row in rows {
            guard let projectId = row.projectId else { continue }
            if rowsByProject[projectId] == nil { projectOrder.append(projectId) }
            rowsByProject[projectId, default: []].append(row)
        }
        let settings = SidebarTabItemSettingsSnapshot()
        let flat = SupermuxMainListFilter.tabsForMainList(tabManager.tabs, tabManager: tabManager)
        return [
            "window_id": AppDelegate.shared?.windowId(for: tabManager)?.uuidString ?? NSNull(),
            "projects": projectOrder.map { id -> [String: Any] in
                ["project_id": id.uuidString, "rows": (rowsByProject[id] ?? []).map(nestedRow)]
            },
            "flat": flat.map { flatRow($0, settings: settings) },
        ]
    }

    private static func nestedRow(_ row: SupermuxOpenWorkspace) -> [String: Any] {
        [
            "workspace_id": row.id.uuidString,
            "title": row.title,
            "device_name": row.device?.name ?? NSNull(),
            "branch": row.branch ?? NSNull(),
            "unread_count": row.unreadCount,
            // What `SupermuxOpenWorkspaceRowView` labels the row with.
            "accessibility_label": row.accessibilityLabel,
        ]
    }

    private static func flatRow(_ workspace: Workspace, settings: SidebarTabItemSettingsSnapshot) -> [String: Any] {
        let snapshot = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: true
        ).makeSnapshot()
        return [
            "workspace_id": workspace.id.uuidString,
            "title": snapshot.title,
            "is_mirror": SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace),
            "device_label": snapshot.deviceWorkspaceLabel ?? NSNull(),
            "subtitle_candidates": snapshot.compactBranchDirectoryCandidates,
            "branch_directory_lines": snapshot.branchDirectoryLines.map(\.directoryCandidates),
        ]
    }

    /// What the window's Projects section is handed about other Macs.
    static func presentation(for tabManager: TabManager) -> [String: Any] {
        let presentation = SupermuxRemoteProjectsPresenter.presentation(for: tabManager)
        return [
            "remote_only_rows": presentation.rows.map { row -> [String: Any] in
                [
                    "id": row.id.uuidString,
                    "name": row.project.name,
                    "device_name": row.location.device?.name ?? NSNull(),
                    "is_online": row.location.isOnline,
                    "is_running": row.isRunning,
                    "has_icon": row.icon != nil,
                    "action_count": row.actions.count,
                    "worktrees": row.worktrees.map(remoteWorktree),
                    "set_up_targets": row.setUpTargets.map(\.name),
                ]
            },
            "local_rows": presentation.extrasByLocalProjectID.map { id, extras -> [String: Any] in
                [
                    "local_project_id": id.uuidString,
                    "location_count": extras.project.locations.count,
                    "worktrees": extras.worktrees.map(remoteWorktree),
                    "set_up_targets": extras.setUpTargets.map(\.name),
                    "remote_url": extras.remoteURL ?? NSNull(),
                ]
            },
        ]
    }

    static func remoteWorktree(_ worktree: SupermuxRemoteWorktree) -> [String: Any] {
        [
            "path": worktree.path,
            "branch": worktree.branch ?? NSNull(),
            "device_name": worktree.location.device?.name ?? NSNull(),
            "project_id": worktree.location.projectID.uuidString,
        ]
    }

    static func syncReport(_ report: SupermuxProjectSyncCoordinator.Report) -> [String: Any] {
        [
            "finished_at": report.finishedAt?.timeIntervalSince1970 ?? NSNull(),
            "registered_here": report.registeredHere,
            "registered_on": report.registeredOn,
            "devices_checked": report.devicesChecked,
        ]
    }
}

import Foundation

/// What each local-path action would do for a workspace, read from the same
/// resolvers the UI uses — so the E2E can prove that a device mirror never
/// offers this Mac's disk for the other Mac's files:
/// - sidebar "Show in Finder": `WorkspaceFinderDirectoryResolver` (nil path
///   disables the row in both sidebar menus),
/// - "Open in <Editor>" / Reveal: the focused pane must allow a local
///   directory (`allowsLocalDirectoryFallback`), else the command palette's
///   open-directory commands have no target,
/// - Files panel: `FileExplorerWorkspaceRootResolver` (a mirror browses the
///   owning Mac's folder over the device link, `kind: "device"`, or names
///   that Mac when it cannot).
@MainActor
enum SupermuxMirrorLocalPathActions {
    static func describe(_ workspace: Workspace) -> [String: Any] {
        let finderPath = WorkspaceFinderDirectoryResolver.path(for: workspace)
        let focusedAllowsLocal = workspace.focusedPanelId.map { workspace.allowsLocalDirectoryFallback(panelId: $0) }
        return [
            "show_in_finder_path": finderPath ?? NSNull(),
            "show_in_finder_enabled": finderPath != nil,
            "open_in_editor_enabled": focusedAllowsLocal ?? !workspace.usesRemoteDirectoryProvenance,
            "file_explorer": fileExplorer(workspace),
        ]
    }

    private static func fileExplorer(_ workspace: Workspace) -> [String: Any] {
        switch FileExplorerWorkspaceRootResolver().resolve(workspace) {
        case .none:
            return ["kind": "none", "is_available": false]
        case .local(_, let path):
            return ["kind": "local", "is_available": true, "root_path": path]
        case .remoteSSH(_, _, let displayTarget, _, let isAvailable, let detail):
            return ["kind": "ssh", "is_available": isAvailable, "display_target": displayTarget, "detail": detail ?? NSNull()]
        case .remoteCloud(_, _, let displayTarget, _, let isAvailable, let detail, _):
            return ["kind": "remote", "is_available": isAvailable, "display_target": displayTarget, "detail": detail ?? NSNull()]
        case .supermuxDevice(let root):
            return ["kind": "device", "is_available": true, "display_target": root.deviceName, "root_path": root.rootPath]
        }
    }
}

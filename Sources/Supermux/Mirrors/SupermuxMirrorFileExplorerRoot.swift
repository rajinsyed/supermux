import Foundation

/// The Files panel root for a device mirror. Upstream already refuses to
/// browse a device-projected workspace on this Mac's disk (it shows an
/// anonymous "Remote files unavailable"); this names the Mac that owns the
/// files, so the panel reads "On <Mac>" instead of looking broken. The fork's
/// file operations (New File, Rename, Trash…) stay hidden with it, since they
/// only attach to a local provider.
///
/// Used by the `mirror-file-explorer-hint` touchpoint in
/// `FileExplorerWorkspaceRootResolver.swift`.
@MainActor
enum SupermuxMirrorFileExplorerRoot {
    /// The unavailable-with-hint root for a mirror; `nil` for other workspaces.
    static func root(for workspace: Workspace) -> FileExplorerWorkspaceRoot? {
        guard let target = SupermuxComposition.mirrorResolver.target(for: workspace) else { return nil }
        return .remoteCloud(
            workspaceId: workspace.id,
            vmID: "",
            displayTarget: target.deviceName,
            rootPath: nil,
            isAvailable: false,
            unavailableDetail: detail(for: target),
            target: nil
        )
    }

    /// "They are on <Mac>." — appended to upstream's "Remote files unavailable: ".
    static func detail(for target: SupermuxMirrorTarget) -> String {
        String(
            localized: "supermux.mirror.files.onMac",
            defaultValue: "They are on \(target.deviceName)."
        )
    }
}

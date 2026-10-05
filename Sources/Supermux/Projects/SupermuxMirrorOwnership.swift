import Foundation

/// What the sidebar's project resolution needs to know about device mirrors:
/// which local workspaces ARE mirrors (they are never claimed by local path
/// association) and which unified project owns each one (from its remote
/// record's `supermux_project_id`). Read once per render pass.
struct SupermuxMirrorOwnership {
    /// Local mirror workspace id → owning unified project id.
    let owners: [UUID: UUID]
    /// Whether some project exists only on other Macs (so the flat-list
    /// filter must run even when this Mac has no projects).
    let hasRemoteOnlyProjects: Bool
    /// Whether a local workspace is a device mirror.
    let isMirror: @MainActor (Workspace) -> Bool

    /// No mirrors and no remote projects (tests and non-device hosts).
    static var none: SupermuxMirrorOwnership {
        SupermuxMirrorOwnership(owners: [:], hasRemoteOnlyProjects: false, isMirror: { _ in false })
    }

    /// The current ownership (reads the observable unified-projects model,
    /// so a SwiftUI body calling this re-renders when ownership changes).
    ///
    /// `isMirror` never reads the surface catalog: a SwiftUI body that did
    /// would re-render on every catalog delta. A binding answers first, so a
    /// mirror the opener just bound is a mirror on the very next render; an
    /// unbound mirror (upstream's `vm.workspace_open`) comes from the model's
    /// last pass, which follows that workspace's panes, so one that gains a
    /// local pane stops being a mirror on the model's next pass.
    @MainActor
    static func current() -> SupermuxMirrorOwnership {
        let unified = SupermuxComposition.unifiedProjects
        let index = SupermuxComposition.deviceWorkspaceIndex
        let mirrorIDs = unified.mirrorWorkspaceIDs
        return SupermuxMirrorOwnership(
            owners: unified.mirrorOwners,
            hasRemoteOnlyProjects: unified.hasRemoteOnlyProjects,
            isMirror: { workspace in
                index.boundRef(forLocal: workspace) != nil || mirrorIDs.contains(workspace.id)
            }
        )
    }

    /// The unified project owning `workspace` when it is a mirror; `nil` for
    /// project-less mirrors. Only meaningful when ``isMirror`` is true.
    func owner(of workspace: Workspace) -> UUID? {
        owners[workspace.id]
    }
}

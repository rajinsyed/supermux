import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// A local workspace mirroring one remote workspace.
struct SupermuxDeviceMirror {
    let ref: SupermuxRemoteWorkspaceRef
    let workspace: Workspace
    /// Whether a persisted binding (not only live projections) names it.
    let isBound: Bool
}

/// Maps local `Workspace`s to the remote workspaces they mirror, across every
/// main window.
///
/// A local workspace mirrors a remote workspace when a persisted binding
/// (``SupermuxDeviceBindingStore``, written by the fork's opener) names it, or
/// when its panes project a device's terminals — live projections and restored
/// ones still waiting for the link (``SurfaceCatalog/pendingRestoredProjections``).
/// The binding wins, so a mirror keeps its identity while its panes are
/// placeholders or all closed.
///
/// ```swift
/// if let ref = index.ref(forLocal: workspace) { index.record(for: ref)?.supermuxProjectID }
/// index.localWorkspace(showing: ref)   // nil → not mirrored here yet
/// ```
@MainActor
final class SupermuxDeviceWorkspaceIndex {
    private let catalog: SurfaceCatalog
    private let devices: SupermuxDevices
    private let bindings: SupermuxDeviceBindingStore
    private let liveWorkspaces: @MainActor () -> [Workspace]

    init(
        catalog: SurfaceCatalog,
        devices: SupermuxDevices,
        bindings: SupermuxDeviceBindingStore,
        liveWorkspaces: @escaping @MainActor () -> [Workspace] = SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces
    ) {
        self.catalog = catalog
        self.devices = devices
        self.bindings = bindings
        self.liveWorkspaces = liveWorkspaces
    }

    /// The host export filter's question (touchpoints #518/#519): whether a
    /// local workspace is a device mirror that this Mac must never re-export
    /// to its phone or to other Macs.
    static func isDeviceMirror(_ workspace: Workspace) -> Bool {
        SupermuxComposition.deviceWorkspaceIndex.isDeviceMirror(workspace)
    }

    // MARK: - Local -> remote

    /// Whether the workspace mirrors a remote workspace: bound, or every pane
    /// projects a device terminal. A workspace mixing local panes with one
    /// borrowed remote pane is a local workspace. O(1) for local workspaces.
    func isDeviceMirror(_ workspace: Workspace) -> Bool {
        if bindings.ref(forStableID: workspace.stableId) != nil { return true }
        guard catalog.projectionMachines(forWorkspace: workspace.id).contains(where: \.isDevice) else { return false }
        let panelIDs = workspace.panels.keys
        guard !panelIDs.isEmpty else { return false }
        return panelIDs.allSatisfy { catalog.machineOwningPanel($0)?.isDevice == true }
    }

    /// The remote workspace a local workspace mirrors, if any.
    func ref(forLocal workspace: Workspace) -> SupermuxRemoteWorkspaceRef? {
        if let bound = bindings.ref(forStableID: workspace.stableId) { return bound }
        return projectedRef(inWorkspace: workspace.id)
    }

    /// The remote workspace a local workspace id mirrors, if any.
    func ref(forLocalWorkspaceID workspaceID: UUID) -> SupermuxRemoteWorkspaceRef? {
        if let workspace = Workspace.liveWorkspace(id: workspaceID) { return ref(forLocal: workspace) }
        return bindings.ref(forWorkspaceID: workspaceID) ?? projectedRef(inWorkspace: workspaceID)
    }

    // MARK: - Remote -> local

    /// The local workspace (in any main window) that mirrors `ref`.
    func localWorkspace(showing ref: SupermuxRemoteWorkspaceRef) -> Workspace? {
        if let stableID = bindings.stableID(for: ref),
           let bound = liveWorkspaces().first(where: { $0.stableId == stableID }) {
            return bound
        }
        var counts: [UUID: Int] = [:]
        for projection in deviceProjections(on: ref.machine) where remoteWorkspaceID(of: projection) == ref.workspaceID {
            counts[projection.workspaceID, default: 0] += 1
        }
        let best = counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.uuidString > rhs.key.uuidString
        }
        return best.flatMap { Workspace.liveWorkspace(id: $0.key) }
    }

    /// The device's synced record for `ref`.
    func record(for ref: SupermuxRemoteWorkspaceRef) -> WorkspaceSyncRecord? {
        devices.record(for: ref)
    }

    /// Every local mirror across all main windows.
    func mirrors() -> [SupermuxDeviceMirror] {
        liveWorkspaces().compactMap { workspace in
            if let bound = bindings.ref(forStableID: workspace.stableId) {
                return SupermuxDeviceMirror(ref: bound, workspace: workspace, isBound: true)
            }
            guard isDeviceMirror(workspace), let ref = projectedRef(inWorkspace: workspace.id) else { return nil }
            return SupermuxDeviceMirror(ref: ref, workspace: workspace, isBound: false)
        }
    }

    // MARK: - Bindings

    /// Records that `workspace` mirrors `ref` (persisted; survives restart).
    func bind(_ workspace: Workspace, to ref: SupermuxRemoteWorkspaceRef) {
        bindings.bind(stableID: workspace.stableId, workspaceID: workspace.id, to: ref)
        devices.scheduleRefresh()
    }

    /// Forgets the binding of a local workspace (call when a mirror closes).
    func unbind(_ workspace: Workspace) {
        bindings.unbind(stableID: workspace.stableId)
        devices.scheduleRefresh()
    }

    /// Forgets the binding of a remote workspace.
    func unbind(ref: SupermuxRemoteWorkspaceRef) {
        bindings.unbind(ref: ref)
        devices.scheduleRefresh()
    }

    /// Drops bindings of workspaces that no longer exist. Call only after the
    /// session restore has finished.
    func pruneBindings() {
        bindings.prune(keepingStableIDs: Set(liveWorkspaces().map(\.stableId)))
    }

    /// The persisted bindings (stable id -> binding), for diagnostics.
    var storedBindings: [UUID: SupermuxDeviceBindingStore.Binding] { bindings.bindings }

    // MARK: - Internals

    /// The device workspace most of this local workspace's panes project.
    private func projectedRef(inWorkspace workspaceID: UUID) -> SupermuxRemoteWorkspaceRef? {
        guard catalog.projectionMachines(forWorkspace: workspaceID).contains(where: \.isDevice) else { return nil }
        var counts: [SupermuxRemoteWorkspaceRef: Int] = [:]
        let live = catalog.projections.filter { $0.workspaceID == workspaceID }
        let pending = catalog.pendingRestoredProjections.projections.filter { $0.workspaceID == workspaceID }
        for projection in Array(live) + pending where projection.resource.machine.isDevice {
            guard let remoteID = remoteWorkspaceID(of: projection) else { continue }
            counts[SupermuxRemoteWorkspaceRef(machine: projection.resource.machine, workspaceID: remoteID), default: 0] += 1
        }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.description > rhs.key.description
        }?.key
    }

    private func deviceProjections(on machine: SurfaceMachineID) -> [SurfaceProjection] {
        Array(catalog.projections.filter { $0.resource.machine == machine })
            + catalog.pendingRestoredProjections.projections.filter { $0.resource.machine == machine }
    }

    private func remoteWorkspaceID(of projection: SurfaceProjection) -> String? {
        let raw = projection.remoteWorkspaceID ?? catalog.resources[projection.resource]?.remoteWorkspace?.id
        return raw.map(SupermuxRemoteWorkspaceRef.canonicalWorkspaceID)
    }

    /// Every workspace in every registered main window.
    static func allMainWindowWorkspaces() -> [Workspace] {
        guard let app = AppDelegate.shared else { return [] }
        return app.listMainWindowSummaries().flatMap { summary in
            app.tabManagerFor(windowId: summary.windowId)?.tabs ?? []
        }
    }
}

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
/// when every pane projects a terminal of that one remote workspace — live
/// projections and restored ones still waiting for the link
/// (``SurfaceCatalog/pendingRestoredProjections``).
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
    /// projects a terminal of one and the same device workspace (the set
    /// upstream's layout coordinator keeps synchronized as that workspace's
    /// view). A workspace mixing local panes with borrowed remote panes, or
    /// borrowing terminals of several remote workspaces, is a local
    /// workspace. O(1) for local workspaces.
    func isDeviceMirror(_ workspace: Workspace) -> Bool {
        if bindings.ref(forStableID: workspace.stableId) != nil { return true }
        guard catalog.projectionMachines(forWorkspace: workspace.id).contains(where: \.isDevice) else { return false }
        let panelIDs = workspace.panels.keys
        guard !panelIDs.isEmpty else { return false }
        var refs = Set<SupermuxRemoteWorkspaceRef>()
        for panelID in panelIDs {
            guard let projection = catalog.projectionIncludingPendingRestore(forPanel: panelID),
                  projection.resource.machine.isDevice,
                  let remoteID = remoteWorkspaceID(of: projection) else { return false }
            refs.insert(SupermuxRemoteWorkspaceRef(machine: projection.resource.machine, workspaceID: remoteID))
        }
        return refs.count == 1
    }

    /// The remote workspace a local workspace mirrors, if any.
    func ref(forLocal workspace: Workspace) -> SupermuxRemoteWorkspaceRef? {
        if let bound = bindings.ref(forStableID: workspace.stableId) { return bound }
        return projectedRef(inWorkspace: workspace.id)
    }

    /// The remote workspace a persisted binding names for `workspace`, ignoring
    /// what its panes project (the fork's opener binds every mirror it opens).
    func boundRef(forLocal workspace: Workspace) -> SupermuxRemoteWorkspaceRef? {
        bindings.ref(forStableID: workspace.stableId)
    }

    /// The remote workspace a local workspace id mirrors, if any.
    func ref(forLocalWorkspaceID workspaceID: UUID) -> SupermuxRemoteWorkspaceRef? {
        if let workspace = Workspace.liveWorkspace(id: workspaceID) { return ref(forLocal: workspace) }
        return bindings.ref(forWorkspaceID: workspaceID) ?? projectedRef(inWorkspace: workspaceID)
    }

    // MARK: - Remote -> local

    /// The local workspace (in any main window) that mirrors `ref`: the bound
    /// one, else an unbound mirror whose every pane shows `ref` (the rule
    /// `mirrors()` uses). A workspace that only borrows some of `ref`'s
    /// terminals does not show it, so auto-mirror and the opener still give
    /// `ref` its own mirror.
    func localWorkspace(showing ref: SupermuxRemoteWorkspaceRef) -> Workspace? {
        if let stableID = bindings.stableID(for: ref),
           let bound = liveWorkspaces().first(where: { $0.stableId == stableID }) {
            return bound
        }
        let candidates = Set(
            deviceProjections(on: ref.machine)
                .filter { remoteWorkspaceID(of: $0) == ref.workspaceID }
                .map(\.workspaceID)
        )
        return candidates.sorted { $0.uuidString < $1.uuidString }
            .compactMap { Workspace.liveWorkspace(id: $0) }
            .first(where: { self.isDeviceMirror($0) && self.ref(forLocal: $0) == ref })
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

    /// Hands `ref`'s binding to `workspace`, a mirror that already shows it
    /// (the duplicate that survives), keeping the remote customization last
    /// applied so its local color, description and pin hold.
    func handOver(_ ref: SupermuxRemoteWorkspaceRef, to workspace: Workspace) {
        bindings.handOver(ref, toStableID: workspace.stableId, workspaceID: workspace.id)
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

    /// The remote color/description/pin last applied to a bound mirror
    /// (persisted with its binding, so it survives a restart).
    func appliedCustomization(for workspace: Workspace) -> SupermuxMirrorCustomization? {
        bindings.appliedCustomization(forStableID: workspace.stableId)
    }

    /// Remembers the remote customization just applied to a bound mirror
    /// (ignored for an unbound one).
    func recordAppliedCustomization(_ customization: SupermuxMirrorCustomization, for workspace: Workspace) {
        bindings.recordAppliedCustomization(customization, forStableID: workspace.stableId)
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

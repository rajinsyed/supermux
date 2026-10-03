import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// Which surfaces of a remote workspace's layout a local mirror cannot show.
///
/// The owning Mac's layout lists every panel (terminals, browsers, markdown,
/// …), but a mirror only materializes terminals. Upstream's layout reconcile
/// expects every layout surface to be a terminal resource and silently stops
/// syncing a workspace that holds anything else. The
/// `device-layout-non-terminal-panels` touchpoint drops these ids before the
/// reconcile, so the mirror still follows the terminals' splits and tabs.
///
/// A surface counts as non-terminal only on positive evidence: the device's
/// synced record lists it with a non-terminal kind, or the catalog holds it as
/// a browser. An id with no evidence yet (a new terminal whose metadata lags)
/// stays in the layout, preserving upstream's wait-for-metadata behavior.
///
/// A terminal whose mirror tab was closed while the link was down is left out
/// the same way until its held close is sent (``SupermuxDeviceHeldCloses``),
/// so the reconcile never shows that tab again on its own.
///
/// The other direction is ``localPanelIDs(in:machine:)``: the mirror's own
/// non-terminal tabs, which never reach the owning Mac's layout.
@MainActor
enum SupermuxDeviceLayoutSurfaceFilter {
    /// A bound mirror's own panels that are not terminals: a browser, file
    /// preview, Markdown or other tab the user opened here. They live only on
    /// this Mac. The `device-layout-local-panels` touchpoint treats them like
    /// reserved panes: left out of every layout sent to the owning Mac and
    /// grafted back where they sit here, so the mirror keeps following that
    /// Mac's splits and tabs. Only a workspace bound as a mirror of `machine`
    /// counts; a local workspace that borrows terminals stays upstream's mixed
    /// workspace. Projected and reserved panes are terminals, so never listed.
    static func localPanelIDs(in workspace: Workspace, machine: SurfaceMachineID) -> Set<UUID> {
        guard SupermuxComposition.deviceWorkspaceIndex.boundRef(forLocal: workspace)?.machine == machine else { return [] }
        return Set(workspace.panels.compactMap { $0.value.panelType == .terminal ? nil : $0.key })
    }

    static func nonTerminalSurfaceIDs(
        in surfaceIDs: [String],
        machine: SurfaceMachineID,
        remoteWorkspaceID: String,
        catalog: SurfaceCatalog
    ) -> Set<String> {
        guard !surfaceIDs.isEmpty else { return [] }
        let ref = SupermuxRemoteWorkspaceRef(machine: machine, workspaceID: remoteWorkspaceID)
        var kinds: [String: String] = [:]
        for surface in SupermuxComposition.devices.record(for: ref)?.surfaces ?? [] {
            kinds[canonical(surface.surfaceID)] = surface.kind
        }
        let held = SupermuxDeviceHeldCloses.shared.surfaceIDs(remoteWorkspaceID: remoteWorkspaceID, on: machine)
        return Set(surfaceIDs.filter { id in
            if held.contains(SupermuxDeviceHeldCloses.canonical(id)) { return true }
            if let kind = kinds[canonical(id)] { return kind != MobileSurfaceKind.terminal.rawValue }
            return catalog.resources[SurfaceResourceID(machine: machine, kind: .browser, key: id)] != nil
        })
    }

    private static func canonical(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString ?? id
    }
}

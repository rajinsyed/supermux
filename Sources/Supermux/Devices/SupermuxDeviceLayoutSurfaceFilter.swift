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
@MainActor
enum SupermuxDeviceLayoutSurfaceFilter {
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

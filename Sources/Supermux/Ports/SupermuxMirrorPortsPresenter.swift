import CmuxSidebar
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// Shows another Mac's ports on the mirrors of its workspaces:
///
/// - upstream's sidebar port chips, filled with the owning Mac's listening
///   ports for that workspace (`applyRemoteDetectedSurfacePortsSnapshot`, the
///   SSH workspaces' path). A chip opens `http://localhost:<port>` in a cmux
///   browser in the mirror, which reaches the owning Mac's port; outside cmux
///   it opens the forward's local port
///   (``SupermuxDevicePortLinks/openChip(_:workspaceID:prefersCmuxBrowser:)``).
/// - a pill (`supermux.ports.<port>`) when a forward landed on another local
///   port, naming where it is reachable here; clicking it opens that URL.
///   The status projector writes only `supermux.remote.*`, so the keys never
///   collide. Flat rows show pills; nested project rows show none.
///
/// Rewritten after every change of the forwards (``SupermuxPortForwards/onChange``),
/// and only where a value changed, so the sidebar does not re-render for nothing.
@MainActor
final class SupermuxMirrorPortsPresenter {
    static let pillKeyPrefix = "supermux.ports."
    /// A fixed timestamp keeps an unchanged pill equal to the one shown.
    private static let pillTimestamp = Date(timeIntervalSinceReferenceDate: 0)

    private let forwards: SupermuxPortForwards
    private let index: SupermuxDeviceWorkspaceIndex
    private let devices: SupermuxDevices
    /// Mirrors written last time, so one that stops being a mirror is cleared.
    private var presented: Set<UUID> = []

    init(forwards: SupermuxPortForwards, index: SupermuxDeviceWorkspaceIndex, devices: SupermuxDevices) {
        self.forwards = forwards
        self.index = index
        self.devices = devices
    }

    func apply() {
        var shown: Set<UUID> = []
        for mirror in index.mirrors() {
            let machine = mirror.ref.machine
            let macName = devices.device(for: machine)?.displayName ?? ""
            let ports = (forwards.hostPorts[machine]?.ports ?? [])
                .filter { SupermuxRemoteWorkspaceRef.canonicalWorkspaceID($0.workspaceID) == mirror.ref.workspaceID }
                .map(\.port)
            let moved = forwards.forwards.values.filter {
                $0.key.machine == machine && $0.workspaceIDs.contains(mirror.ref.workspaceID)
            }
            shown.insert(mirror.workspace.id)
            applyChips(Array(Set(ports)).sorted(), to: mirror.workspace, macName: macName)
            applyPills(pills(for: Array(moved), macName: macName), to: mirror.workspace)
        }
        for id in presented.subtracting(shown) {
            guard let workspace = Workspace.liveWorkspace(id: id) else { continue }
            applyChips([], to: workspace, macName: "")
            applyPills([:], to: workspace)
        }
        presented = shown
    }

    private func applyChips(_ ports: [Int], to workspace: Workspace, macName: String) {
        guard workspace.remoteDetectedPorts != ports else { return }
        workspace.applyRemoteDetectedSurfacePortsSnapshot(
            detectedByPanel: [:], detected: ports, forwarded: [], conflicts: [], target: macName
        )
    }

    /// A pill for each active forward that landed on another local port.
    private func pills(for forwards: [SupermuxPortForwards.Forward], macName: String) -> [String: SidebarStatusEntry] {
        var pills: [String: SidebarStatusEntry] = [:]
        for forward in forwards {
            let remote = forward.key.remotePort
            guard let local = forward.localPort, local != remote else { continue }
            let key = Self.pillKeyPrefix + String(remote)
            pills[key] = SidebarStatusEntry(
                key: key,
                value: String(
                    localized: "supermux.ports.pill",
                    defaultValue: "Port \(String(remote)) from \(macName) is at localhost:\(String(local))"
                ),
                icon: "arrow.left.arrow.right.circle",
                url: URL(string: "http://localhost:\(local)"),
                timestamp: Self.pillTimestamp
            )
        }
        return pills
    }

    private func applyPills(_ wanted: [String: SidebarStatusEntry], to workspace: Workspace) {
        for key in workspace.statusEntries.keys where key.hasPrefix(Self.pillKeyPrefix) && wanted[key] == nil {
            workspace.removeStatusEntry(forKey: key)
        }
        for (key, entry) in wanted where workspace.statusEntries[key] != entry {
            workspace.setStatusEntry(entry, key: key, panelId: nil)
        }
    }
}

import AppKit
import Bonsplit
import CmuxSimulatorStreamKit
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Simulators in device mirrors run on the Mac that owns the workspace.
///
/// "New Simulator" in a mirror (menu, palette, plus menu, shortcut, tab-bar
/// button) opens a viewer tab here (``SupermuxRemoteSimulatorPanel``) that
/// shows the source workspace's first Simulator no viewer here shows yet, or
/// opens a new one there (attach or create). A mirror never makes a local
/// `SimulatorPanel`, so nothing simulator-related runs or is stored on this
/// Mac. Upstream calls in through the `remote-simulator-*` touchpoints.
@MainActor
final class SupermuxRemoteSimulators {
    static var shared: SupermuxRemoteSimulators { SupermuxComposition.remoteSimulators }

    private let devices: SupermuxDevices
    private let index: SupermuxDeviceWorkspaceIndex

    init(devices: SupermuxDevices, index: SupermuxDeviceWorkspaceIndex) {
        self.devices = devices
        self.index = index
    }

    /// The `remote-simulator-no-local-in-mirror` guard: whether `workspace`
    /// must never make a local simulator (it is a device mirror).
    static func blocksLocalSimulator(in workspace: Workspace) -> Bool {
        SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace)
    }

    /// "New Simulator" in `workspace`. In a device mirror this shows the
    /// owning Mac's simulator in a viewer tab in `paneId` and returns true,
    /// also when that Mac is offline or too old (an alert says so; there is
    /// no local fallback). Returns false for any other workspace, whose
    /// caller makes a local simulator as before.
    @discardableResult
    func openIfDeviceMirror(_ workspace: Workspace, paneId: PaneID, focus: Bool) -> Bool {
        guard Self.blocksLocalSimulator(in: workspace) else { return false }
        guard let ref = index.ref(forLocal: workspace) else { return true }
        let machine = ref.machine
        guard devices.device(for: machine)?.isConnected == true else {
            SupermuxRemoteSimulatorAlerts.presentOffline(macName(machine))
            return true
        }
        guard let panel = workspace.newSupermuxRemoteSimulatorSurface(
            inPane: paneId,
            machine: machine,
            remoteWorkspaceID: ref.workspaceID,
            focus: focus
        ) else { return true }
        Task { await attachOrCreate(panel) }
        return true
    }

    /// The remote workspace a mirror shows, for restoring its viewer tabs.
    func mirroredRef(of workspace: Workspace) -> SupermuxRemoteWorkspaceRef? {
        index.ref(forLocal: workspace)
    }

    // MARK: - Finding the host panel

    /// Attach or create: the source workspace's first Simulator panel that no
    /// viewer here shows yet, else a new one there.
    func attachOrCreate(_ panel: SupermuxRemoteSimulatorPanel) async {
        guard await checkCapabilities(panel) else { return }
        do {
            let host = panel.hostClient
            let listed = try await host.panelIDs()
            // Read after the await, so a viewer that attached meanwhile counts.
            let shown = shownHostPanelIDs(on: panel.machine, besides: panel)
            if let free = listed.first(where: { !shown.contains($0) }) {
                panel.attach(hostPanelID: free, deviceUDID: nil)
            } else {
                attach(panel, toNewPanel: try await host.create(udid: nil), deviceUDID: nil)
            }
        } catch {
            panel.attachFailed(error.localizedDescription)
        }
    }

    /// Finds `panel`'s simulator again after a relaunch, a reconnect, or the
    /// owning Mac's restart: its own host panel, else that workspace's panel
    /// showing its device, else (when `create`) a new panel on that device.
    /// Without `create`, a panel that is gone shows "Closed on <Mac>".
    func rebind(_ panel: SupermuxRemoteSimulatorPanel, create: Bool) async {
        guard await checkCapabilities(panel) else { return }
        do {
            let host = panel.hostClient
            let listed = try await host.panelIDs()
            if let saved = panel.hostPanelID, listed.contains(saved) {
                panel.attach(hostPanelID: saved, deviceUDID: nil)
                return
            }
            if let udid = panel.deviceUDID {
                for candidate in listed {
                    let showsDevice = try await host.deviceList(panelID: candidate)
                        .contains { $0.isSelected && $0.udid == udid }
                    // Read after each await, so a viewer that attached meanwhile counts.
                    let shown = shownHostPanelIDs(on: panel.machine, besides: panel)
                    if showsDevice, !shown.contains(candidate) {
                        panel.attach(hostPanelID: candidate, deviceUDID: udid)
                        return
                    }
                }
            }
            guard create else {
                panel.markClosedOnHost()
                return
            }
            let created = try await host.create(udid: panel.deviceUDID)
            if let udid = panel.deviceUDID, !panel.supportsControls {
                // An older owning Mac ignores `udid` on create.
                try? await host.select(udid: udid, panelID: created)
            }
            attach(panel, toNewPanel: created, deviceUDID: panel.deviceUDID)
        } catch {
            panel.attachFailed(error.localizedDescription)
        }
    }

    /// Shows a host panel just opened for `panel`, or closes it again there
    /// when the viewer tab was closed while it was being opened.
    private func attach(_ panel: SupermuxRemoteSimulatorPanel, toNewPanel created: UUID, deviceUDID: String?) {
        guard !panel.isClosed else {
            let host = panel.hostClient
            Task { try? await host.close(panelID: created) }
            return
        }
        panel.attach(hostPanelID: created, deviceUDID: deviceUDID)
    }

    /// Whether the owning Mac can stream its simulators here. When it says
    /// it cannot (too old, or its simulators are turned off), the viewer tab
    /// closes and an alert says why; when it did not answer, the tab stays
    /// with Open Again.
    private func checkCapabilities(_ panel: SupermuxRemoteSimulatorPanel) async -> Bool {
        guard let capabilities = await devices.hostCapabilities(on: panel.machine) else {
            panel.attachFailed(String(
                localized: "supermux.remoteSimulator.state.unreachable",
                defaultValue: "Couldn’t reach \(panel.macName)"
            ))
            return false
        }
        guard capabilities.contains(SupermuxMobileCapability.panesV1.rawValue) else {
            SupermuxRemoteSimulatorAlerts.presentNeedsUpdate(panel.macName)
            panel.dismissKeepingHostPanel()
            return false
        }
        // The owning Mac withholds the stream capability while its simulators are turned off.
        guard capabilities.contains(SimStreamProtocol().capability) else {
            SupermuxRemoteSimulatorAlerts.presentTurnedOff(panel.macName)
            panel.dismissKeepingHostPanel()
            return false
        }
        panel.supportsControls = capabilities.contains(SupermuxMobileCapability.remoteSimulatorV1.rawValue)
        return true
    }

    /// The host panels other viewers on this Mac already show.
    private func shownHostPanelIDs(on machine: SurfaceMachineID, besides panel: SupermuxRemoteSimulatorPanel) -> Set<UUID> {
        var shown = Set<UUID>()
        for workspace in SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces() {
            for case let viewer as SupermuxRemoteSimulatorPanel in workspace.panels.values
            where viewer !== panel && viewer.machine == machine {
                if let id = viewer.hostPanelID { shown.insert(id) }
            }
        }
        return shown
    }

    private func macName(_ machine: SurfaceMachineID) -> String {
        devices.device(for: machine)?.displayName ?? machine.rawValue
    }
}

@MainActor
extension SupermuxComposition {
    /// Simulators in device mirrors (viewer tabs of the owning Mac's simulators).
    static let remoteSimulators = SupermuxRemoteSimulators(devices: devices, index: deviceWorkspaceIndex)
}

/// Why "New Simulator" in a mirror opened nothing, naming the owning Mac.
@MainActor
enum SupermuxRemoteSimulatorAlerts {
    static func presentOffline(_ macName: String) {
        present(
            title: String(
                localized: "supermux.remoteSimulator.alert.offline.title",
                defaultValue: "\(macName) is offline"
            ),
            message: String(
                localized: "supermux.remoteSimulator.alert.offline.message",
                defaultValue: "Simulators in this workspace run on \(macName). Connect to it to show them here."
            )
        )
    }

    static func presentNeedsUpdate(_ macName: String) {
        present(
            title: String(
                localized: "supermux.remoteSimulator.alert.update.title",
                defaultValue: "Can’t show \(macName)’s simulators"
            ),
            message: String(
                localized: "supermux.remoteSimulator.alert.update.message",
                defaultValue: "Update Supermux on \(macName) to show its simulators here."
            )
        )
    }

    static func presentTurnedOff(_ macName: String) {
        present(
            title: String(
                localized: "supermux.remoteSimulator.state.disabled",
                defaultValue: "Simulators are turned off on \(macName)"
            ),
            message: ""
        )
    }

    private static func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        SupermuxAlertPresentation.show(alert, preferring: NSApp.keyWindow ?? NSApp.mainWindow)
    }
}

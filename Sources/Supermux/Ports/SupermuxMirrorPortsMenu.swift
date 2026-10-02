import AppKit
import CmuxSurfaceCatalogModel
import SupermuxKit
import SwiftUI

/// "Ports on <Mac>", in a mirror row's context menu (flat rows through
/// ``SupermuxMirrorRowMenuItems``, nested project rows through
/// `SupermuxRemoteProjectActions.mirrorMenu`): this workspace's ports on its
/// Mac first, then that Mac's other forwarded ports, each with Open in cmux
/// Browser (in this mirror, which reaches that Mac), Open in Default Browser
/// and Copy Local URL (the forward here), and Stop Forwarding or Forward to
/// This Mac; then Forward a Port…. While the Mac cannot forward, one disabled
/// line says why.
struct SupermuxMirrorPortsMenu: View {
    let workspaceId: UUID

    var body: some View {
        if let ref = SupermuxComposition.deviceWorkspaceIndex.ref(forLocalWorkspaceID: workspaceId) {
            content(machine: ref.machine, remoteWorkspaceID: ref.workspaceID)
        }
    }

    @ViewBuilder
    private func content(machine: SurfaceMachineID, remoteWorkspaceID: String) -> some View {
        let forwards = SupermuxComposition.portForwards
        let macName = SupermuxComposition.devices.device(for: machine)?.displayName ?? ""
        let ownPorts = Set((forwards.hostPorts[machine]?.ports ?? [])
            .filter { SupermuxRemoteWorkspaceRef.canonicalWorkspaceID($0.workspaceID) == remoteWorkspaceID }
            .map(\.port)).sorted()
        let otherPorts = forwards.forwards.keys
            .filter { $0.machine == machine && !ownPorts.contains($0.remotePort) }
            .map(\.remotePort)
            .sorted()
        Menu(String(localized: "supermux.ports.menu.title", defaultValue: "Ports on \(macName)")) {
            if let reason = SupermuxPortsText.unavailable(forwards.availability[machine], macName: macName) {
                Text(reason)
            } else {
                if ownPorts.isEmpty, otherPorts.isEmpty {
                    Text(String(localized: "supermux.ports.menu.none", defaultValue: "No ports detected"))
                }
                ForEach(ownPorts, id: \.self) { port in
                    portMenu(machine: machine, remotePort: port)
                }
                if !otherPorts.isEmpty {
                    Section(String(localized: "supermux.ports.menu.otherPorts", defaultValue: "Other forwarded ports")) {
                        ForEach(otherPorts, id: \.self) { port in
                            portMenu(machine: machine, remotePort: port)
                        }
                    }
                }
                Divider()
                Button(String(localized: "supermux.ports.menu.forwardPort", defaultValue: "Forward a Port…")) {
                    SupermuxPortForwardPrompt.present(machine: machine, macName: macName)
                }
            }
        }
    }

    private func portMenu(machine: SurfaceMachineID, remotePort: Int) -> some View {
        let forwards = SupermuxComposition.portForwards
        let localPort = forwards.localPort(machine: machine, remotePort: remotePort)
        let workspaceId = workspaceId
        return Menu(SupermuxPortsText.menuLabel(remotePort: remotePort, localPort: localPort)) {
            Button(String(localized: "supermux.ports.menu.openCmux", defaultValue: "Open in cmux Browser")) {
                SupermuxMirrorPortsActions.openInCmuxBrowser(workspaceID: workspaceId, remotePort: remotePort)
            }
            if let localPort {
                Button(String(localized: "supermux.ports.menu.openDefault", defaultValue: "Open in Default Browser")) {
                    SupermuxMirrorPortsActions.openInDefaultBrowser(localPort: localPort)
                }
                Button(String(localized: "supermux.ports.menu.copy", defaultValue: "Copy Local URL")) {
                    SupermuxMirrorPortsActions.copyLocalURL(localPort: localPort)
                }
                Button(String(localized: "supermux.ports.menu.stop", defaultValue: "Stop Forwarding")) {
                    Task { await forwards.stop(machine: machine, remotePort: remotePort) }
                }
            } else {
                Button(String(localized: "supermux.ports.menu.forward", defaultValue: "Forward to This Mac")) {
                    Task { await forwards.resume(machine: machine, remotePort: remotePort) }
                }
            }
        }
    }
}

/// What the port menus (a mirror row's and Settings') and a mirror's port
/// chips do with one port.
@MainActor
enum SupermuxMirrorPortsActions {
    /// The remote workspace `workspaceID` mirrors, by the rule of
    /// `SupermuxDeviceWorkspaceIndex.mirrors()` (the workspaces whose chips
    /// show another Mac's ports and whose browsers reach that Mac); nil for
    /// any other workspace, also a local one that borrows a remote terminal.
    static func mirrorRef(workspaceID: UUID) -> SupermuxRemoteWorkspaceRef? {
        let index = SupermuxComposition.deviceWorkspaceIndex
        guard let workspace = Workspace.liveWorkspace(id: workspaceID), index.isDeviceMirror(workspace) else { return nil }
        return index.ref(forLocal: workspace)
    }

    /// Says why a port does not open here (an OK-only alert).
    static func showNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        SupermuxAlertPresentation.show(alert, preferring: NSApp.keyWindow)
    }

    /// The owning Mac's `localhost:<port>` in a cmux browser in the mirror
    /// (its browser reaches that Mac).
    static func openInCmuxBrowser(workspaceID: UUID, remotePort: Int) {
        guard let url = URL(string: "http://localhost:\(remotePort)") else { return }
        AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?.openBrowser(inWorkspace: workspaceID, url: url)
    }

    /// The forward's local URL in the default browser.
    static func openInDefaultBrowser(localPort: Int) {
        guard let url = localURL(localPort) else { return }
        _ = NSWorkspace.shared.open(url)
    }

    static func copyLocalURL(localPort: Int) {
        guard let url = localURL(localPort) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private static func localURL(_ port: Int) -> URL? {
        URL(string: "http://localhost:\(port)")
    }
}

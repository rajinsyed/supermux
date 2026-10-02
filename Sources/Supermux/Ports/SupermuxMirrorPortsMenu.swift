import AppKit
import CmuxSettingsUI
import CmuxSurfaceCatalogModel
import SupermuxKit
import SwiftUI

/// "Ports on <Mac>", in a mirror row's context menu (flat rows through
/// ``SupermuxMirrorRowMenuItems``, nested project rows through
/// `SupermuxRemoteProjectActions.mirrorMenu`), as ``SupermuxMirrorPortsMenuModel``
/// describes it: this workspace's ports on its Mac first, then that Mac's
/// other forwarded ports, each with Open in cmux Browser (in this mirror,
/// which reaches that Mac) and the items both port menus share
/// (``SupermuxPortMenuItems``); then Forward a Port…. While the Mac cannot
/// forward, one disabled line says why, and its pending forwards still offer
/// Stop Forwarding.
struct SupermuxMirrorPortsMenu: View {
    let workspaceId: UUID

    var body: some View {
        if let model = SupermuxMirrorPortsMenuModel(workspaceID: workspaceId) {
            Menu(model.title) {
                if let reason = model.reason {
                    Text(reason)
                } else if model.ownPorts.isEmpty, model.otherPorts.isEmpty {
                    Text(String(localized: "supermux.ports.menu.none", defaultValue: "No ports detected"))
                }
                ForEach(model.ownPorts, id: \.remotePort) { port in
                    portMenu(port, machine: model.machine)
                }
                if !model.otherPorts.isEmpty {
                    Section(String(localized: "supermux.ports.menu.otherPorts", defaultValue: "Other forwarded ports")) {
                        ForEach(model.otherPorts, id: \.remotePort) { port in
                            portMenu(port, machine: model.machine)
                        }
                    }
                }
                if model.offersForwardPort {
                    Divider()
                    Button(String(localized: "supermux.ports.menu.forwardPort", defaultValue: "Forward a Port…")) {
                        SupermuxPortForwardPrompt.present(machine: model.machine, macName: model.macName)
                    }
                }
            }
        }
    }

    private func portMenu(_ port: SupermuxMirrorPortsMenuModel.Port, machine: SurfaceMachineID) -> some View {
        let workspaceId = workspaceId
        return Menu(port.label) {
            if port.opensInCmuxBrowser {
                Button(String(localized: "supermux.ports.menu.openCmux", defaultValue: "Open in cmux Browser")) {
                    SupermuxMirrorPortsActions.openInCmuxBrowser(workspaceID: workspaceId, remotePort: port.remotePort)
                }
            }
            ForEach(port.actions, id: \.self) { action in
                Button(SupermuxPortMenuItems.title(action)) {
                    SupermuxMirrorPortsActions.perform(action, machine: machine, remotePort: port.remotePort)
                }
            }
        }
    }
}

/// What a mirror's "Ports on <Mac>" shows (the DEBUG `ports.menus` driver
/// reports it too). Only for a device mirror (``SupermuxMirrorPortsActions/mirrorRef(workspaceID:)``),
/// the workspaces whose browsers reach their Mac.
struct SupermuxMirrorPortsMenuModel {
    struct Port {
        let remotePort: Int
        /// `localhost:3000`, or `localhost:3000 → here :3001`.
        let label: String
        /// Open in cmux Browser, while the Mac can forward.
        let opensInCmuxBrowser: Bool
        let actions: [SupermuxRemoteMacPortAction]
    }

    let machine: SurfaceMachineID
    let macName: String
    /// Why the Mac cannot forward right now; nil when it can.
    let reason: String?
    /// This workspace's ports on its Mac: listed for it, or forwarded for it.
    let ownPorts: [Port]
    /// That Mac's other forwarded ports.
    let otherPorts: [Port]

    var title: String {
        String(localized: "supermux.ports.menu.title", defaultValue: "Ports on \(macName)")
    }

    /// Forward a Port…, while the Mac can forward (else the forward would
    /// only wait, and start listening later on its own).
    var offersForwardPort: Bool { reason == nil }

    @MainActor
    init?(workspaceID: UUID) {
        guard let ref = SupermuxMirrorPortsActions.mirrorRef(workspaceID: workspaceID) else { return nil }
        let forwards = SupermuxComposition.portForwards
        let machine = ref.machine
        let macName = SupermuxComposition.devices.device(for: machine)?.displayName ?? ""
        let reason = SupermuxPortsText.unavailable(forwards.availability[machine], macName: macName)
        let listed = (forwards.hostPorts[machine]?.ports ?? [])
            .filter { SupermuxRemoteWorkspaceRef.canonicalWorkspaceID($0.workspaceID) == ref.workspaceID }
            .map(\.port)
        let forwarded = forwards.forwards.values.filter { $0.key.machine == machine }
        let own = Set(listed).union(forwarded.filter { $0.workspaceIDs.contains(ref.workspaceID) }.map(\.key.remotePort))
        let other = Set(forwarded.map(\.key.remotePort)).subtracting(own)
        self.machine = machine
        self.macName = macName
        self.reason = reason
        ownPorts = Self.ports(own, machine: machine, canForward: reason == nil)
        otherPorts = Self.ports(other, machine: machine, canForward: reason == nil)
    }

    /// The ports that offer anything, by port number.
    @MainActor
    private static func ports(_ remotePorts: Set<Int>, machine: SurfaceMachineID, canForward: Bool) -> [Port] {
        let forwards = SupermuxComposition.portForwards
        return remotePorts.sorted().compactMap { remotePort in
            let actions = SupermuxPortMenuItems.actions(machine: machine, remotePort: remotePort)
            guard canForward || !actions.isEmpty else { return nil }
            return Port(
                remotePort: remotePort,
                label: SupermuxPortsText.menuLabel(
                    remotePort: remotePort,
                    localPort: forwards.localPort(machine: machine, remotePort: remotePort)
                ),
                opensInCmuxBrowser: canForward,
                actions: actions
            )
        }
    }
}

/// The items both port menus (a mirror row's "Ports on <Mac>" and Settings'
/// "Ports…") offer for one of another Mac's ports, in this order:
///
/// - Open in Default Browser and Copy Local URL, while it listens here.
/// - Stop Forwarding, for every forward that exists and is not stopped
///   (active, starting, waiting or failed), also while its Mac cannot
///   forward, so a pending forward never starts listening later on its own.
/// - Forward to This Mac, while the Mac can forward and the port has no
///   forward, or one the user stopped or that failed (a retry).
@MainActor
enum SupermuxPortMenuItems {
    static func actions(machine: SurfaceMachineID, remotePort: Int) -> [SupermuxRemoteMacPortAction] {
        let forwards = SupermuxComposition.portForwards
        let forward = forwards.forwards[SupermuxPortForwards.Key(machine: machine, remotePort: remotePort)]
        var actions: [SupermuxRemoteMacPortAction] = []
        if forward?.localPort != nil {
            actions.append(.openInBrowser)
            actions.append(.copyLocalURL)
        }
        if let forward, forward.state != .stopped {
            actions.append(.stopForwarding)
        }
        if forwards.availability[machine] == .available, isRestartable(forward) {
            actions.append(.forward)
        }
        return actions
    }

    static func title(_ action: SupermuxRemoteMacPortAction) -> String {
        switch action {
        case .openInBrowser:
            return String(localized: "supermux.ports.menu.openDefault", defaultValue: "Open in Default Browser")
        case .copyLocalURL:
            return String(localized: "supermux.ports.menu.copy", defaultValue: "Copy Local URL")
        case .stopForwarding:
            return String(localized: "supermux.ports.menu.stop", defaultValue: "Stop Forwarding")
        case .forward:
            return String(localized: "supermux.ports.menu.forward", defaultValue: "Forward to This Mac")
        }
    }

    /// No forward, or one the user stopped or that failed.
    private static func isRestartable(_ forward: SupermuxPortForwards.Forward?) -> Bool {
        guard let forward else { return true }
        if case .failed = forward.state { return true }
        return forward.state == .stopped
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

    /// Runs one port menu item (both menus).
    static func perform(_ action: SupermuxRemoteMacPortAction, machine: SurfaceMachineID, remotePort: Int) {
        let forwards = SupermuxComposition.portForwards
        let localPort = forwards.localPort(machine: machine, remotePort: remotePort)
        switch action {
        case .openInBrowser:
            if let localPort { openInDefaultBrowser(localPort: localPort) }
        case .copyLocalURL:
            if let localPort { copyLocalURL(localPort: localPort) }
        case .stopForwarding:
            Task { await forwards.stop(machine: machine, remotePort: remotePort) }
        case .forward:
            Task { await forwards.resume(machine: machine, remotePort: remotePort) }
        }
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
        // The user's own choice: it may forward one of that Mac's other ports.
        SupermuxSamePortForwardGate.noteUserOpen(port: remotePort)
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

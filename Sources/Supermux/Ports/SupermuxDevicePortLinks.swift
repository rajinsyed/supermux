import AppKit
import CmuxCore
import Foundation

/// Links to `localhost` that name another Mac's port: terminal links in its
/// mirrored terminals, and the sidebar port chips of its mirrors.
///
/// - The `device-mirror-link-forward` touchpoint in `TerminalLinkOpenCoordinator`
///   passes upstream's destinations through ``destinations(_:sourceWorkspaceID:)``:
///   a link that leaves cmux (the default browser) opens at the local port this
///   Mac forwards that port to.
/// - The `device-mirror-port-chip` touchpoint in upstream's two chip handlers
///   (`ContentView`) sends a mirror's chip click to
///   ``openChip(_:workspaceID:prefersCmuxBrowser:)``, which does the same for
///   a chip of one of the owning Mac's ports, and opens a chip of this Mac's
///   own port at this Mac's `localhost` outside the mirror's browsers.
///
/// The cmux browser keeps the owning Mac's link as written, since a mirror's
/// browser reaches the owning Mac itself.
@MainActor
enum SupermuxDevicePortLinks {
    /// `destinations` with the external URL moved to the forward's local
    /// port, when the link is an http(s) loopback URL in a device mirror and
    /// its port is forwarded to another local port; else unchanged (a port
    /// that is not forwarded opens as written).
    static func destinations(_ destinations: RemoteLinkDestinations, sourceWorkspaceID: UUID?) -> RemoteLinkDestinations {
        guard let url = destinations.externalURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, RemoteLoopbackProxyAlias.isLoopbackHost(host),
              let remotePort = url.port,
              let sourceWorkspaceID,
              let ref = SupermuxComposition.deviceWorkspaceIndex.ref(forLocalWorkspaceID: sourceWorkspaceID),
              let localPort = SupermuxComposition.portForwards.localPort(machine: ref.machine, remotePort: remotePort),
              localPort != remotePort,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return destinations
        }
        components.port = localPort
        return RemoteLinkDestinations(browserURL: destinations.browserURL, externalURL: components.url ?? url)
    }

    // MARK: - Sidebar port chips

    /// Whether `workspaceID`'s sidebar port chips take
    /// ``openChip(_:workspaceID:prefersCmuxBrowser:)`` instead of upstream's
    /// path: it is a device mirror, whose browsers reach the owning Mac.
    static func isMirror(workspaceID: UUID) -> Bool {
        SupermuxMirrorPortsActions.mirrorRef(workspaceID: workspaceID) != nil
    }

    /// Whether `workspaceID`'s sidebar port chip for `port` is another Mac's
    /// port: the workspace is a device mirror, `port` is one of the owning
    /// Mac's ports ``SupermuxMirrorPortsPresenter`` gave it, and no panel of
    /// this Mac in it listens on `port` (a terminal of this Mac moved into the
    /// mirror shows its own ports there too). Any other chip is this Mac's own
    /// port.
    static func isMirrorChip(workspaceID: UUID, port: Int) -> Bool {
        guard isMirror(workspaceID: workspaceID),
              let workspace = Workspace.liveWorkspace(id: workspaceID),
              workspace.remoteDetectedPorts.contains(port) else { return false }
        let listensHere = workspace.surfaceListeningPorts.values.contains { $0.contains(port) }
            || workspace.agentListeningPorts.contains(port)
        return !listensHere
    }

    /// A device mirror's port chip click. The owning Mac's port
    /// (``isMirrorChip(workspaceID:port:)``): with "Open Sidebar Port Links in
    /// cmux Browser" on, `http://localhost:<port>` opens in a cmux browser in
    /// the mirror, as upstream does (it reaches the owning Mac); otherwise, or
    /// when no cmux browser opens, the default browser gets the local port
    /// this Mac forwards that port to, never this Mac's own `localhost:<port>`;
    /// with no active forward nothing opens and an alert says why (the Mac
    /// cannot forward now, or the port is not forwarded). A port of this Mac
    /// (a terminal of this Mac moved into the mirror) opens at this Mac's
    /// `http://localhost:<port>` in the default browser, also with that
    /// setting on: every browser of a mirror routes `localhost` to the owning
    /// Mac, so a cmux browser there would show that Mac's server.
    static func openChip(_ port: Int, workspaceID: UUID, prefersCmuxBrowser: Bool) {
        openChip(
            port,
            workspaceID: workspaceID,
            prefersCmuxBrowser: prefersCmuxBrowser,
            openExternally: { _ = NSWorkspace.shared.open($0) },
            explain: { SupermuxMirrorPortsActions.showNotice($0) }
        )
    }

    /// ``openChip(_:workspaceID:prefersCmuxBrowser:)`` with its two ways out
    /// of cmux passed in (the DEBUG driver captures them).
    static func openChip(
        _ port: Int,
        workspaceID: UUID,
        prefersCmuxBrowser: Bool,
        openExternally: (URL) -> Void,
        explain: (String) -> Void
    ) {
        guard let ref = SupermuxMirrorPortsActions.mirrorRef(workspaceID: workspaceID),
              let url = URL(string: "http://localhost:\(port)") else { return }
        guard isMirrorChip(workspaceID: workspaceID, port: port) else {
            openExternally(url)
            return
        }
        if prefersCmuxBrowser {
            // The user's own click: it may get a same-port forward like a typed URL.
            SupermuxSamePortForwardGate.noteUserOpen(machine: ref.machine, port: port)
        }
        if prefersCmuxBrowser,
           AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?.openBrowser(
               inWorkspace: workspaceID, url: url, preferSplitRight: true, insertAtEnd: true
           ) != nil {
            return
        }
        let forwards = SupermuxComposition.portForwards
        if let localPort = forwards.localPort(machine: ref.machine, remotePort: port),
           let localURL = URL(string: "http://localhost:\(localPort)") {
            openExternally(localURL)
            return
        }
        let macName = SupermuxComposition.devices.device(for: ref.machine)?.displayName ?? ""
        explain(SupermuxPortsText.unavailable(forwards.availability[ref.machine], macName: macName)
            ?? SupermuxPortsText.notForwarded(remotePort: port, macName: macName))
    }
}

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
///   (`ContentView`) sends a mirror's chip click to ``openMirrorChip(_:workspaceID:prefersCmuxBrowser:)``,
///   which does the same for a chip.
///
/// The cmux browser keeps the link as written, since a mirror's browser
/// reaches the owning Mac itself.
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

    /// Whether `workspaceID`'s sidebar port chips are another Mac's ports:
    /// it is a device mirror (``SupermuxMirrorPortsPresenter`` fills them).
    static func isMirrorChip(workspaceID: UUID) -> Bool {
        SupermuxMirrorPortsActions.mirrorRef(workspaceID: workspaceID) != nil
    }

    /// A device mirror's port chip click. With "Open Sidebar Port Links in
    /// cmux Browser" on, `http://localhost:<port>` opens in a cmux browser in
    /// the mirror, as upstream does (it reaches the owning Mac). Otherwise, or
    /// when no cmux browser opens, the default browser gets the local port
    /// this Mac forwards that port to, never this Mac's own
    /// `localhost:<port>`; with no active forward nothing opens and an alert
    /// says why (the Mac cannot forward now, or the port is not forwarded).
    static func openMirrorChip(_ port: Int, workspaceID: UUID, prefersCmuxBrowser: Bool) {
        openMirrorChip(
            port,
            workspaceID: workspaceID,
            prefersCmuxBrowser: prefersCmuxBrowser,
            openExternally: { _ = NSWorkspace.shared.open($0) },
            explain: { SupermuxMirrorPortsActions.showNotice($0) }
        )
    }

    /// ``openMirrorChip(_:workspaceID:prefersCmuxBrowser:)`` with its two ways
    /// out of cmux passed in (the DEBUG driver captures them).
    static func openMirrorChip(
        _ port: Int,
        workspaceID: UUID,
        prefersCmuxBrowser: Bool,
        openExternally: (URL) -> Void,
        explain: (String) -> Void
    ) {
        guard let ref = SupermuxMirrorPortsActions.mirrorRef(workspaceID: workspaceID),
              let url = URL(string: "http://localhost:\(port)") else { return }
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

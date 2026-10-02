import CmuxCore
import Foundation

/// Terminal links to `localhost` in another Mac's mirrored terminal name that
/// Mac's port. The `device-mirror-link-forward` touchpoint in
/// `TerminalLinkOpenCoordinator` passes upstream's destinations through here:
/// a link that leaves cmux (the default browser) opens at the local port this
/// Mac forwards that port to. The cmux browser keeps the link as written,
/// since a mirror's browser reaches the owning Mac itself.
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
}

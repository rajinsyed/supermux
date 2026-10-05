import Foundation

/// SUPERMUX — what the Remote Macs settings card shows: the fork's four
/// remote-Mac preferences, every Mac the fork knows with its link state, its
/// route while connected and its ports, and how many remote workspaces are
/// hidden with "Hide Here".
///
/// Built app-side (`SupermuxRemoteMacsSettingsFeed`) from the device facade,
/// `SupermuxDevicesSettings` and the hidden set; this package only renders it.
public struct SupermuxRemoteMacsSettingsSnapshot: Equatable, Sendable {
    /// One of another Mac's ports, as this Mac sees it.
    public struct Port: Identifiable, Equatable, Sendable {
        /// The port on the other Mac.
        public let remotePort: Int
        /// Where it opens on this Mac; nil while it is not forwarded.
        public let localPort: Int?
        /// Whether it is forwarded (or waits to be): the Ports line lists it.
        public let isForwarded: Bool
        /// Its text in the Ports line (`:3000`, `:8081 → here :8082`).
        public let lineText: String
        /// Its title in the Ports… menu (`localhost:3000 → here :3001`).
        public let menuLabel: String
        /// Its Ports… submenu, in order; empty leaves it out of the menu. The
        /// app decides it as for a mirror row's "Ports on <Mac>" (Stop
        /// Forwarding for every forward that is not stopped, also a pending one).
        public let actions: [SupermuxRemoteMacPortAction]

        public var id: Int { remotePort }

        public init(
            remotePort: Int,
            localPort: Int?,
            isForwarded: Bool,
            lineText: String,
            menuLabel: String,
            actions: [SupermuxRemoteMacPortAction] = []
        ) {
            self.remotePort = remotePort
            self.localPort = localPort
            self.isForwarded = isForwarded
            self.lineText = lineText
            self.menuLabel = menuLabel
            self.actions = actions
        }
    }

    /// One other Mac.
    public struct Mac: Identifiable, Equatable, Sendable {
        /// The link, reduced to what the card says about it.
        public enum Link: String, Equatable, Sendable {
            case connected
            case connecting
            case offline
        }

        /// Which path a connected Mac's link uses, as the row says it.
        public struct Route: Equatable, Sendable {
            /// The localized words: `Direct · LAN · 6 ms`, `Relay · Tokyo · 241 ms`.
            public let label: String
            /// Whether it goes through a relay (the row tints it amber).
            public let isRelayed: Bool

            public init(label: String, isRelayed: Bool) {
                self.label = label
                self.isRelayed = isRelayed
            }
        }

        /// The catalog machine id (`device:<uuid>@<tag>`).
        public let id: String
        public let name: String
        public let link: Link
        /// Why the Mac is offline or still connecting, when known.
        public let detail: String?
        /// Its link's route while connected; nil otherwise (the row then
        /// shows its status).
        public let route: Route?
        /// Its synced workspaces (0 until the link has fetched them).
        public let workspaceCount: Int
        /// Its listed and forwarded ports.
        public let ports: [Port]
        /// Why its ports cannot be forwarded right now (an older Supermux, no
        /// direct connection), shown instead of them.
        public let portsNote: String?

        /// Whether its ports can be forwarded now (Forward a Port…).
        public var canForwardPorts: Bool { link == .connected && portsNote == nil }

        /// Whether its row shows the Ports… menu: while it can forward, and
        /// while a port still offers something (a pending forward's Stop
        /// Forwarding, also while it is offline or cannot forward).
        public var showsPortsMenu: Bool { canForwardPorts || ports.contains { !$0.actions.isEmpty } }

        public init(
            id: String,
            name: String,
            link: Link,
            detail: String?,
            route: Route? = nil,
            workspaceCount: Int,
            ports: [Port] = [],
            portsNote: String? = nil
        ) {
            self.id = id
            self.name = name
            self.link = link
            self.detail = detail
            self.route = route
            self.workspaceCount = workspaceCount
            self.ports = ports
            self.portsNote = portsNote
        }
    }

    /// `supermux.devices.autoMirror`: every other Mac's workspaces in the sidebar.
    public var autoMirror: Bool
    /// `supermux.devices.syncProjects`: register projects across Macs.
    public var syncProjects: Bool
    /// `supermux.devices.sharePush`: share the phone-push setup between Macs.
    public var sharePush: Bool
    /// `supermux.devices.forwardPorts`: forward other Macs' workspace ports here.
    public var forwardPorts: Bool
    public var macs: [Mac]
    /// Remote workspaces hidden with "Hide Here".
    public var hiddenWorkspaceCount: Int

    public init(
        autoMirror: Bool = true,
        syncProjects: Bool = true,
        sharePush: Bool = true,
        forwardPorts: Bool = true,
        macs: [Mac] = [],
        hiddenWorkspaceCount: Int = 0
    ) {
        self.autoMirror = autoMirror
        self.syncProjects = syncProjects
        self.sharePush = sharePush
        self.forwardPorts = forwardPorts
        self.macs = macs
        self.hiddenWorkspaceCount = hiddenWorkspaceCount
    }
}

import Foundation

/// SUPERMUX — what the Remote Macs settings card shows: the fork's four
/// remote-Mac preferences, every Mac the fork knows with its link state and
/// its ports, and how many remote workspaces are hidden with "Hide Here".
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

        public var id: Int { remotePort }

        public init(remotePort: Int, localPort: Int?, isForwarded: Bool, lineText: String, menuLabel: String) {
            self.remotePort = remotePort
            self.localPort = localPort
            self.isForwarded = isForwarded
            self.lineText = lineText
            self.menuLabel = menuLabel
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

        /// The catalog machine id (`device:<uuid>@<tag>`).
        public let id: String
        public let name: String
        public let link: Link
        /// Why the Mac is offline or still connecting, when known.
        public let detail: String?
        /// Its synced workspaces (0 until the link has fetched them).
        public let workspaceCount: Int
        /// Its listed and forwarded ports.
        public let ports: [Port]
        /// Why its ports cannot be forwarded right now (an older Supermux, no
        /// direct connection), shown instead of them.
        public let portsNote: String?

        public init(
            id: String,
            name: String,
            link: Link,
            detail: String?,
            workspaceCount: Int,
            ports: [Port] = [],
            portsNote: String? = nil
        ) {
            self.id = id
            self.name = name
            self.link = link
            self.detail = detail
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

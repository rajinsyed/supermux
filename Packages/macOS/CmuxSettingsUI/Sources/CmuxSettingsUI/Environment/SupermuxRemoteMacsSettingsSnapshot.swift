import Foundation

/// SUPERMUX — what the Remote Macs settings card shows: the fork's three
/// remote-Mac preferences, every Mac the fork knows with its link state, and
/// how many remote workspaces are hidden with "Hide Here".
///
/// Built app-side (`SupermuxRemoteMacsSettingsFeed`) from the device facade,
/// `SupermuxDevicesSettings` and the hidden set; this package only renders it.
public struct SupermuxRemoteMacsSettingsSnapshot: Equatable, Sendable {
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

        public init(id: String, name: String, link: Link, detail: String?, workspaceCount: Int) {
            self.id = id
            self.name = name
            self.link = link
            self.detail = detail
            self.workspaceCount = workspaceCount
        }
    }

    /// `supermux.devices.autoMirror`: every other Mac's workspaces in the sidebar.
    public var autoMirror: Bool
    /// `supermux.devices.syncProjects`: register projects across Macs.
    public var syncProjects: Bool
    /// `supermux.devices.sharePush`: share the phone-push setup between Macs.
    public var sharePush: Bool
    public var macs: [Mac]
    /// Remote workspaces hidden with "Hide Here".
    public var hiddenWorkspaceCount: Int

    public init(
        autoMirror: Bool = true,
        syncProjects: Bool = true,
        sharePush: Bool = true,
        macs: [Mac] = [],
        hiddenWorkspaceCount: Int = 0
    ) {
        self.autoMirror = autoMirror
        self.syncProjects = syncProjects
        self.sharePush = sharePush
        self.macs = macs
        self.hiddenWorkspaceCount = hiddenWorkspaceCount
    }
}

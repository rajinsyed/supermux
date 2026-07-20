import Foundation
public import CmuxMobileShellModel

extension MobileWorkspacePreview {
    /// Build a preview value from a remote workspace-list entry.
    /// - Parameter remote: A workspace decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Workspace) {
        self.init(
            id: ID(rawValue: remote.id),
            windowID: remote.windowID,
            name: remote.title,
            currentDirectory: remote.currentDirectory,
            isPinned: remote.isPinned ?? false,
            groupID: remote.groupID.map { MobileWorkspaceGroupPreview.ID(rawValue: $0) },
            previewText: remote.preview,
            previewAt: remote.previewAt.map { Date(timeIntervalSince1970: $0) },
            lastActivityAt: remote.lastActivityAt.map { Date(timeIntervalSince1970: $0) },
            hasUnread: remote.hasUnread ?? false,
            terminals: remote.terminals.map { terminal in
                MobileTerminalPreview(remote: terminal)
            }
        )
        // SUPERMUX:begin supermux-mobile-workspace-fields (carry the additive §6 fields into the preview — see SUPERMUX-TOUCHPOINTS.md)
        self.supermuxProjectID = remote.supermuxProjectID
        self.supermuxActivity = remote.supermuxActivity
        self.supermuxBranch = remote.supermuxBranch
        self.supermuxPullRequestNumber = remote.supermuxPullRequest?.number ?? nil
        self.supermuxPullRequestState = remote.supermuxPullRequest?.state
        self.supermuxPullRequestURL = remote.supermuxPullRequest?.url
        self.supermuxPullRequestIsStale = remote.supermuxPullRequest?.isStale ?? nil
        // SUPERMUX:end supermux-mobile-workspace-fields
    }
}

extension MobileWorkspaceGroupPreview {
    /// Build a group preview value from a remote workspace-list group entry.
    /// - Parameter remote: A group decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Group) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.name,
            isCollapsed: remote.isCollapsed,
            isPinned: remote.isPinned,
            anchorWorkspaceID: MobileWorkspacePreview.ID(rawValue: remote.anchorWorkspaceID)
        )
    }
}

extension MobileTerminalPreview {
    /// Build a preview value from a remote terminal entry.
    /// - Parameter remote: A terminal decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Terminal) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.title,
            currentDirectory: remote.currentDirectory,
            isReady: remote.isReady ?? true,
            isFocused: remote.isFocused
        )
    }
}

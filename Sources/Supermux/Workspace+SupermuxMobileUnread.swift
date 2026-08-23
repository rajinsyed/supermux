import CmuxNotifications
import Foundation

extension Workspace {
    /// Returns pane ids that should display the same unread indicator as macOS.
    @MainActor
    func supermuxMobileUnreadPanelIDs(
        notificationStore: TerminalNotificationStore?
    ) -> [String] {
        supermuxMobileUnreadPanelIDs(
            unreadSnapshot: notificationStore?.sidebarUnread.snapshot
        )
    }

    /// Returns pane ids from the immutable unread snapshot shared by sidebar consumers.
    @MainActor
    func supermuxMobileUnreadPanelIDs(
        unreadSnapshot: SidebarUnreadSnapshot?
    ) -> [String] {
        guard let unreadSnapshot else { return [] }
        let isWorkspaceManuallyUnread = unreadSnapshot.hasManualUnread(
            forWorkspaceId: id
        )
        let manualUnreadRepresentative = representativePanelIdForWorkspaceManualUnread()

        return orderedPanelIds.compactMap { panelID in
            guard panels[panelID] != nil else { return nil }
            let showsIndicator = Self.shouldShowUnreadIndicator(
                hasUnreadNotification: unreadSnapshot.hasVisibleNotificationIndicator(
                    forWorkspaceId: id,
                    surfaceId: panelID
                ),
                hasPanelUnreadIndicator: manualUnreadPanelIds.contains(panelID)
                    || restoredUnreadPanelIds.contains(panelID),
                isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                isWorkspaceManualUnreadRepresentative: manualUnreadRepresentative == panelID
            )
            return showsIndicator ? panelID.uuidString : nil
        }
    }
}

import Foundation

extension Workspace {
    /// Returns pane ids that should display the same unread indicator as macOS.
    @MainActor
    func supermuxMobileUnreadPanelIDs(
        notificationStore: TerminalNotificationStore?
    ) -> [String] {
        guard let notificationStore else { return [] }
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(
            forTabId: id
        )
        let manualUnreadRepresentative = representativePanelIdForWorkspaceManualUnread()

        return orderedPanelIds.compactMap { panelID in
            guard panels[panelID] != nil else { return nil }
            let showsIndicator = Self.shouldShowUnreadIndicator(
                hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                    forTabId: id,
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

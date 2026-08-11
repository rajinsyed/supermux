import Foundation

/// The single user-initiated "toggle read" path, shared by every surface that
/// offers it (the titlebar popover row and the notifications panel row).
///
/// This exists because the behavior is not just `isRead = !isRead`: marking a
/// pane-scoped notification read must ALSO clear that pane's focused-read
/// indicator, or the pane keeps a badge for a notification the user just
/// dismissed. That subtlety lived inline in one surface only, so a second
/// surface offering the same menu item would have silently lacked it.
extension TerminalNotificationStore {
    /// Toggles a notification's read state the way a user action should.
    ///
    /// Marking read clears the owning pane's focused-read indicator for
    /// pane-scoped notifications. Workspace-level notifications
    /// (`surfaceId == nil`) deliberately skip that: `clearFocusedReadIndicator`
    /// treats a nil surface as "clear any pane indicator on this tab", which
    /// would wipe an unrelated pane's badge.
    ///
    /// - Parameter notification: The notification whose read state to flip.
    func toggleReadFromUserAction(_ notification: TerminalNotification) {
        if notification.isRead {
            markUnread(id: notification.id)
            return
        }
        markRead(id: notification.id)
        guard let surfaceId = notification.surfaceId else { return }
        clearFocusedReadIndicator(forTabId: notification.tabId, surfaceId: surfaceId)
    }
}

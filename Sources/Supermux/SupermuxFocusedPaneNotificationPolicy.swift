import Foundation

/// Resolves whether a notification target is the pane already visible to the user.
struct SupermuxFocusedPaneNotificationPolicy {
    /// Returns whether the exact pane target is already visible and focused.
    func targetIsAlreadyVisible(
        surfaceID: UUID?,
        externalDeliverySuppressed: Bool,
        targetWindowIsKey: Bool = true
    ) -> Bool {
        _ = targetWindowIsKey
        return surfaceID != nil && externalDeliverySuppressed
    }

    /// Removes user-facing alert effects while preserving history and automation.
    func resolvedEffects(
        _ effects: TerminalNotificationPolicyEffects,
        targetIsAlreadyVisible: Bool
    ) -> TerminalNotificationPolicyEffects {
        guard targetIsAlreadyVisible else { return effects }

        var resolved = effects
        resolved.markUnread = false
        resolved.reorderWorkspace = false
        resolved.desktop = false
        resolved.sound = false
        resolved.paneFlash = false
        return resolved
    }
}

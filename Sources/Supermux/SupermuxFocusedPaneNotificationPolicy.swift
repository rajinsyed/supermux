import Foundation

/// Resolves whether a notification target is the pane already visible to the
/// user, for the direct phone push only (`direct-phone-push` fence in
/// `TerminalNotificationStore`): such a notification is not pushed to the
/// phone (`skip_focused_pane`). On the Mac it is handled exactly as upstream
/// handles a focused-pane arrival: unread, with the pane ring and the tab
/// badge until the user clicks or types in the pane, and no banner.
///
/// "Visible" needs all of: an exact pane target, that pane focused in the
/// frontmost cmux window (`exactPaneFocused`, the store's
/// `isFocusedSurfaceArrival`), its window key, and someone actually at this
/// Mac (``SupermuxMacPresence``). The presence rule keeps an unattended Mac
/// pushing an agent's notification to the phone even though its pane happens
/// to be focused on a locked or idle screen.
///
/// Never feed it the store's external-delivery gate: with upstream's
/// `notifications.suppressWhenAppFocused` on, that gate is merely "cmux is
/// frontmost", which would skip the phone push for every pane. That setting
/// withholds only the banner.
@MainActor
struct SupermuxFocusedPaneNotificationPolicy {
    #if DEBUG
    /// E2E override for the target window's key state (`nil` = live). A
    /// background-launched tagged build never has a key window.
    static var debugTargetWindowIsKey: Bool?
    #endif

    private let userIsPresent: @MainActor () -> Bool

    /// - Parameter userIsPresent: Presence source; defaults to the live Mac
    ///   presence shared with upstream's `onlyWhenAway` gate.
    init(userIsPresent: @escaping @MainActor () -> Bool = { SupermuxMacPresence.isUserPresent() }) {
        self.userIsPresent = userIsPresent
    }

    /// Returns whether the exact pane target is already visible and focused
    /// by a user who is at this Mac.
    /// - Parameters:
    ///   - surfaceID: The notification's pane, or `nil` for a workspace target.
    ///   - exactPaneFocused: That pane is the focused surface of the selected
    ///     workspace while cmux is frontmost (`isFocusedSurfaceArrival`).
    ///   - targetWindowIsKey: Whether the target's window is key.
    func targetIsAlreadyVisible(
        surfaceID: UUID?,
        exactPaneFocused: Bool,
        targetWindowIsKey: Bool = true
    ) -> Bool {
        guard surfaceID != nil, exactPaneFocused, Self.windowIsKey(targetWindowIsKey) else {
            return false
        }
        // Evaluated last: presence reads system state, so only a focused-pane
        // arrival pays for it.
        return userIsPresent()
    }

    private static func windowIsKey(_ live: Bool) -> Bool {
        #if DEBUG
        if let debugTargetWindowIsKey { return debugTargetWindowIsKey }
        #endif
        return live
    }
}

import Foundation

/// Resolves whether a notification target is the pane already visible to the user.
///
/// "Visible" needs all of: an exact pane target, that pane focused in the
/// frontmost cmux window (`externalDeliverySuppressed`), its window key, and
/// someone actually at this Mac (``SupermuxMacPresence``). The presence rule
/// keeps an unattended Mac from recording an agent's notification as already
/// read (and skipping the phone push) just because its pane happens to be
/// focused on a locked or idle screen.
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
    func targetIsAlreadyVisible(
        surfaceID: UUID?,
        externalDeliverySuppressed: Bool,
        targetWindowIsKey: Bool = true
    ) -> Bool {
        guard surfaceID != nil, externalDeliverySuppressed, Self.windowIsKey(targetWindowIsKey) else {
            return false
        }
        // Evaluated last: presence reads system state, so only a focused-pane
        // arrival pays for it.
        return userIsPresent()
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

    private static func windowIsKey(_ live: Bool) -> Bool {
        #if DEBUG
        if let debugTargetWindowIsKey { return debugTargetWindowIsKey }
        #endif
        return live
    }
}

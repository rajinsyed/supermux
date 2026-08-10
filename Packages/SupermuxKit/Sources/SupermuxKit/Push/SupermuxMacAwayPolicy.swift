public import Foundation

/// Decides whether the Mac's user should be treated as away for phone push.
///
/// Upstream suppresses every external delivery while the Mac app is frontmost
/// on the target terminal, assuming a frontmost app means a watching user. A
/// phone remote-controlling the Mac breaks that assumption: selection sync
/// keeps the Mac focused on whatever workspace the phone views, so agent
/// notifications for exactly the session the user cares about were never
/// forwarded. This policy reinstates delivery when the evidence says nobody is
/// physically at the Mac — the screen is locked, or no local keyboard/mouse
/// input has arrived for ``idleThreshold``. Phone-side foreground suppression
/// still prevents a duplicate banner when the phone is actively showing the
/// exact target terminal.
public struct SupermuxMacAwayPolicy: Sendable, Equatable {
    /// Seconds without local HID input after which the user counts as away.
    public let idleThreshold: TimeInterval

    /// Creates the policy.
    ///
    /// - Parameter idleThreshold: Seconds of local input silence treated as
    ///   away. Defaults to 60, matching the agent idle-reminder cadence so a
    ///   turn that finishes right after the user leaves is at most one
    ///   reminder late.
    public init(idleThreshold: TimeInterval = 60) {
        self.idleThreshold = idleThreshold
    }

    /// Whether the user should be treated as away from the Mac.
    ///
    /// - Parameters:
    ///   - screenLocked: Whether the login session reports a locked screen.
    ///   - secondsSinceLastInput: Seconds since the last physical keyboard or
    ///     mouse event, or `nil` when the host cannot measure it. Unknown
    ///     input recency fails closed (present), preserving upstream
    ///     suppression.
    /// - Returns: `true` when external delivery should proceed despite app
    ///   focus.
    public func isAway(
        screenLocked: Bool,
        secondsSinceLastInput: TimeInterval?
    ) -> Bool {
        if screenLocked { return true }
        guard let secondsSinceLastInput, secondsSinceLastInput.isFinite else {
            return false
        }
        return secondsSinceLastInput >= idleThreshold
    }
}

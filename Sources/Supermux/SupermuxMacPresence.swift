import Foundation

/// Whether someone is at this Mac right now, for the focused-pane policy.
///
/// The same signals upstream's `onlyWhenAway` phone gate evaluates (console
/// session unlocked, displays awake, no screensaver, hardware input within
/// ``MacPresenceMonitor/recentHardwareInputThreshold``), read through the same
/// monitor instance `PhonePushClient` owns. An unattended Mac (the MacBook
/// where agents run, with Supermux frontmost and the agent's pane focused)
/// must not treat that pane as "already seen": nobody is looking at it.
@MainActor
enum SupermuxMacPresence {
    /// Cached like upstream's gate (an active verdict is reused for one
    /// second; an away verdict is always re-evaluated).
    private static var cache = MacPresenceDecisionCache()

    #if DEBUG
    /// E2E override: `true` = present, `false` = away, `nil` = live signals.
    static var debugOverride: Bool?
    #endif

    /// Whether the user is at this Mac.
    ///
    /// An explicit app-focus override (`AppFocusState.overrideIsFocused`, set by
    /// tests and debug tooling) simulates the user, so presence follows it.
    static func isUserPresent() -> Bool {
        #if DEBUG
        if let debugOverride { return debugOverride }
        #endif
        if let simulatedFocus = AppFocusState.overrideIsFocused { return simulatedFocus }
        return cache.decision(from: PhonePushClient.shared.presenceMonitor).isActive
    }

    /// Where the answer came from, for DEBUG introspection.
    static func source() -> String {
        #if DEBUG
        if let debugOverride { return debugOverride ? "debug_present" : "debug_away" }
        #endif
        if AppFocusState.overrideIsFocused != nil { return "app_focus_override" }
        return "live"
    }
}

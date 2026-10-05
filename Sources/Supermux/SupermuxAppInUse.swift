import AppKit

/// Whether someone may be looking at this Mac's app right now: it is active,
/// or one of its main windows is on screen and not fully covered. Never
/// while Remote Host Mode keeps it headless. Background work only the user
/// sees (worktree sweeps, the route a remote Mac's link uses) runs faster
/// while this is true.
@MainActor
enum SupermuxAppInUse {
    /// Whether the app is in use (see the type's documentation).
    static func now() -> Bool {
        let hostMode = SupermuxRemoteHostMode.shared
        guard !hostMode.isHeadless else { return false }
        return NSApp.isActive || hostMode.visibleMainWindows().contains { $0.occlusionState.contains(.visible) }
    }
}

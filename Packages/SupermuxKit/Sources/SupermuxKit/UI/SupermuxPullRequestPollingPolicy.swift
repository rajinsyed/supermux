/// Host-supplied policy for the unopened-worktree pull-request probe driven by
/// ``SupermuxProjectsSectionView``.
///
/// cmux gates all of its own PR probing behind user settings
/// (`watchGitStatus && showPullRequests`, cmux's
/// `SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled`); the host passes
/// that flag here so the supermux probe honors the same switches instead of
/// polling GitHub for users who turned PR polling off. The interval mirrors
/// cmux's poll cadence. Defaults preserve the section's standalone behavior:
/// enabled, on screen, 60-second re-polls.
public struct SupermuxPullRequestPollingPolicy: Hashable, Sendable {
    /// Re-poll cadence while the section's window is off screen. Polling only
    /// slows there: a headless host's phones still read these badges, and
    /// ``isEnabled`` stays the one switch that clears them.
    public static let offScreenInterval: Duration = .seconds(300)

    /// Whether PR probing and badges are enabled. When `false` the section
    /// clears existing worktree badges and never touches the network.
    public var isEnabled: Bool
    /// Delay between periodic re-polls of an unchanged target set while the
    /// section's window is on screen.
    public var interval: Duration
    /// Whether the section's window is on screen (not minimized, covered,
    /// hidden or ordered out by Remote Host Mode).
    public var isOnScreen: Bool

    /// Creates a policy.
    /// - Parameters:
    ///   - isEnabled: Whether probing runs at all; defaults to `true`.
    ///   - interval: Re-poll cadence on screen; defaults to 60 seconds.
    ///   - isOnScreen: Whether the section's window is on screen; defaults to `true`.
    public init(isEnabled: Bool = true, interval: Duration = .seconds(60), isOnScreen: Bool = true) {
        self.isEnabled = isEnabled
        self.interval = interval
        self.isOnScreen = isOnScreen
    }

    /// The re-poll delay in effect: ``interval`` on screen, at least
    /// ``offScreenInterval`` off screen.
    public var effectiveInterval: Duration {
        isOnScreen ? interval : max(interval, Self.offScreenInterval)
    }
}

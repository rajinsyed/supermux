/// Host-supplied policy for the unopened-worktree pull-request probe driven by
/// ``SupermuxProjectsSectionView``.
///
/// cmux gates all of its own PR probing behind user settings
/// (`watchGitStatus && showPullRequests`, cmux's
/// `SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled`); the host passes
/// that flag here so the supermux probe honors the same switches instead of
/// polling GitHub for users who turned PR polling off. The interval mirrors
/// cmux's poll cadence. Defaults preserve the section's standalone behavior:
/// enabled, 60-second re-polls.
public struct SupermuxPullRequestPollingPolicy: Hashable, Sendable {
    /// Whether PR probing and badges are enabled. When `false` the section
    /// clears existing worktree badges and never touches the network.
    public var isEnabled: Bool
    /// Delay between periodic re-polls of an unchanged target set.
    public var interval: Duration

    /// Creates a policy.
    /// - Parameters:
    ///   - isEnabled: Whether probing runs at all; defaults to `true`.
    ///   - interval: Re-poll cadence; defaults to 60 seconds.
    public init(isEnabled: Bool = true, interval: Duration = .seconds(60)) {
        self.isEnabled = isEnabled
        self.interval = interval
    }
}

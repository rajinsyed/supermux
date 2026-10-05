// SUPERMUX:begin agent-feed-retry-backoff
import Foundation

/// Which connection a Mac's agent-feed refresh task serves. A refresh for an
/// earlier connection is replaced, not joined, and only the task holding the
/// current token unregisters itself when it ends.
struct SupermuxAgentFeedRefreshOwner {
    let token = UUID()
    let client: ObjectIdentifier
}

extension MobileShellComposite {
    /// Failed `feed.list` attempts a refresh makes before it waits for the
    /// next trigger (`feed.changed`, a new connection, a pull to refresh).
    static let supermuxAgentFeedMaximumFailedAttempts = 3

    /// Waits before the agent feed's next attempt after `failures`
    /// consecutive failed fetches: 1 s, then 2 s. False once the refresh
    /// should stop (the attempts are spent, or it was cancelled).
    func supermuxAgentFeedRetryWait(afterFailures failures: Int) async -> Bool {
        guard failures < Self.supermuxAgentFeedMaximumFailedAttempts else { return false }
        let delay = Duration.seconds(1 << min(max(failures - 1, 0), 4))
        do {
            try await controlPlaneSchedulingClock.sleep(for: delay)
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}
// SUPERMUX:end agent-feed-retry-backoff

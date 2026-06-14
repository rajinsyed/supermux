public import Foundation

/// A pull request associated with a worktree (or its opened workspace), reduced
/// to the fields the sidebar badge needs.
///
/// One value type bridges both sources of PR state so the sidebar renders a
/// single, consistent badge wherever a worktree appears:
/// - opened worktrees nest as live workspace rows whose PR comes straight from
///   cmux's own probe (cmux's `SidebarPullRequestState`), and
/// - unopened worktrees are resolved by ``SupermuxPullRequestProbe`` (cmux's
///   `CmuxGit` pipeline).
///
/// It is a pure value — no store, and it imports neither SwiftUI nor CmuxGit —
/// so it crosses the sidebar snapshot boundary into rows freely.
public struct SupermuxPullRequest: Hashable, Sendable {
    /// The lifecycle state of a pull request, matching GitHub's reported states.
    ///
    /// Raw values are the stable `"open"`/`"merged"`/`"closed"` strings shared
    /// with cmux's `SidebarPullRequestStatus` and `CmuxGit.PullRequestStatus`, so
    /// both bridge in via `rawValue` without a mapping table.
    public enum Status: String, Hashable, Sendable, CaseIterable {
        /// The pull request is open.
        case open
        /// The pull request was merged.
        case merged
        /// The pull request was closed without merging.
        case closed
    }

    /// The pull request number (the `#1234` shown on the badge).
    public let number: Int
    /// The pull request's lifecycle state (drives the badge icon and color).
    public let status: Status
    /// The PR's web URL, opened when the badge is clicked.
    public let url: URL
    /// Whether the badge is stale (kept after repeated probe failures); rendered
    /// dimmed, mirroring cmux's own stale-PR treatment.
    public let isStale: Bool

    /// Creates a pull request badge value.
    /// - Parameters:
    ///   - number: The PR number.
    ///   - status: The PR's lifecycle state.
    ///   - url: The PR's web URL.
    ///   - isStale: Whether the badge should render dimmed; defaults to `false`.
    public init(number: Int, status: Status, url: URL, isStale: Bool = false) {
        self.number = number
        self.status = status
        self.url = url
        self.isStale = isStale
    }
}

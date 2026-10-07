public import Foundation

/// The pull request cmux already tracks for a workspace, reduced to the
/// fields the Changes panel's PR header needs to show and open it.
///
/// The host bridges it from cmux's own per-workspace probe (cmux's
/// `SidebarPullRequestState`), so no fetch of supermux's own runs for it.
///
/// It is a pure value — no store, and it imports neither SwiftUI nor CmuxGit —
/// so it crosses view boundaries freely.
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

    /// The pull request number.
    public let number: Int
    /// The pull request's lifecycle state.
    public let status: Status
    /// The PR's web URL.
    public let url: URL
    /// The PR's title, when the source that produced this value carries one.
    ///
    /// cmux's probe pipeline does not surface titles today, so production
    /// values are `nil` until it does; the PR viewer loads the title on click.
    public let title: String?

    /// Creates a pull request value.
    /// - Parameters:
    ///   - number: The PR number.
    ///   - status: The PR's lifecycle state.
    ///   - url: The PR's web URL.
    ///   - title: The PR's title, when known; defaults to `nil`.
    public init(number: Int, status: Status, url: URL, title: String? = nil) {
        self.number = number
        self.status = status
        self.url = url
        self.title = title
    }
}

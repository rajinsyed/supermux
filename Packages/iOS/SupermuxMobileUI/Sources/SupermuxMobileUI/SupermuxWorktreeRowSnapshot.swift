public import Foundation
public import SupermuxMobileCore

/// A pull request's lifecycle state, as the phone's badge renders it —
/// mirroring the desktop `SupermuxPullRequestBadge` states (green open,
/// purple merged, red closed). Unknown future spellings degrade to a neutral
/// badge, never a failure.
public enum SupermuxPullRequestBadgeState: Equatable, Sendable {
    /// The PR is open.
    case open
    /// The PR was merged.
    case merged
    /// The PR was closed without merging.
    case closed
    /// Any other (or missing) state string.
    case unknown

    /// Maps the wire state string onto a badge state.
    /// - Parameter state: The DTO's raw state string.
    public init(state: String?) {
        switch state?.lowercased() {
        case "open": self = .open
        case "merged": self = .merged
        case "closed": self = .closed
        default: self = .unknown
        }
    }
}

/// Immutable value snapshot of a worktree's pull-request badge: number +
/// state color only (the Mac has no PR-title source — production `title` is
/// always nil, same as the desktop badge). Tapping opens ``url`` locally.
public struct SupermuxPullRequestBadgeSnapshot: Equatable, Sendable {
    /// The PR number.
    public let number: Int
    /// The badge's state (drives the tint).
    public let state: SupermuxPullRequestBadgeState
    /// The PR's web URL, when present and parseable.
    public let url: URL?

    /// Projects a wire DTO onto the badge snapshot.
    /// - Parameter dto: The worktree's pull request, if any.
    public init?(dto: SupermuxPullRequestDTO?) {
        guard let dto else { return nil }
        self.number = dto.number
        self.state = SupermuxPullRequestBadgeState(state: dto.state)
        self.url = dto.url.flatMap(URL.init(string:))
    }
}

/// Immutable value snapshot of one worktree row in the project detail's
/// Worktrees section. Rows below the `List` boundary receive ONLY this (plus
/// closure action bundles) — never a store reference — per the repo's
/// snapshot-boundary rule.
public struct SupermuxWorktreeRowSnapshot: Equatable, Identifiable, Sendable {
    /// The worktree's absolute path on the Mac — the stable identity.
    public let id: String
    /// The worktree's absolute path on the Mac.
    public let path: String
    /// The checked-out branch, or the path's last component when detached.
    public let displayName: String
    /// Whether the worktree has uncommitted changes (`false` when unknown).
    public let isDirty: Bool
    /// Whether a workspace is currently open in this worktree.
    public let isOpen: Bool
    /// The open workspace's id, when ``isOpen`` is true.
    public let workspaceID: String?
    /// The PR badge, when a pull request is known.
    public let pullRequest: SupermuxPullRequestBadgeSnapshot?

    /// Projects a wire DTO onto the row snapshot.
    /// - Parameter worktree: The worktree as fetched from the Mac.
    public init(worktree: SupermuxWorktreeDTO) {
        self.id = worktree.path
        self.path = worktree.path
        let fallback = (worktree.path as NSString).lastPathComponent
        let branch = worktree.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (branch?.isEmpty == false ? branch : nil) ?? fallback
        self.isDirty = worktree.isDirty ?? false
        self.isOpen = worktree.isOpen ?? false
        self.workspaceID = worktree.workspaceId
        self.pullRequest = SupermuxPullRequestBadgeSnapshot(dto: worktree.pullRequest)
    }

    /// Projects the store's worktrees onto rows, preserving the Mac's order.
    /// - Parameter worktrees: The worktrees as fetched from the Mac.
    public static func rows(from worktrees: [SupermuxWorktreeDTO]) -> [SupermuxWorktreeRowSnapshot] {
        worktrees.map(SupermuxWorktreeRowSnapshot.init(worktree:))
    }

    /// The rows for the inline project disclosure: only worktrees WITHOUT an
    /// open workspace, in the Mac's order — open ones already render as
    /// nested workspace rows, so the disclosure never duplicates them
    /// (mirrors the mac sidebar's `SupermuxUnopenedWorktrees.filter`). A
    /// missing `is_open` (older Mac) degrades to "not open" so the row stays
    /// reachable.
    /// - Parameter worktrees: The worktrees as fetched from the Mac.
    public static func unopenedRows(from worktrees: [SupermuxWorktreeDTO]) -> [SupermuxWorktreeRowSnapshot] {
        rows(from: worktrees).filter { !$0.isOpen }
    }
}

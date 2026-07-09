public import CmuxMobileShellModel
public import Foundation
public import SupermuxMobileCore

/// Immutable value snapshot of one open workspace nested under a project —
/// the phone-side projection of the §6 `supermux_project_id` /
/// `supermux_activity` / `supermux_branch` / `supermux_pull_request`
/// workspace-list fields. Rendered by the inline nested rows and the project
/// detail screen's Workspaces section, and counted by the project row badge;
/// passed across the shell's `List` boundary as pure values per the repo's
/// snapshot-boundary rule.
public struct SupermuxProjectWorkspaceRowSnapshot: Equatable, Identifiable, Sendable {
    /// The workspace's UI row identifier (the shell's `MobileWorkspacePreview.ID`
    /// raw value) — exactly what the shell's `selectWorkspace` expects back.
    public let id: String
    /// The Mac-local workspace id (the shell's `rpcWorkspaceID`) — what the
    /// Mac's `run.state` rows reference via `workspace_id`, so the run
    /// indicator can be matched even when the UI row id is Mac-scoped.
    public let remoteID: String
    /// The owning project's UUID string (from `supermux_project_id`).
    public let projectID: String
    /// The workspace's user-facing display name.
    public let name: String
    /// The workspace's agent activity, or `nil` when idle (or the Mac sent an
    /// unknown future spelling — degrade to "no dot", never fail).
    public let activity: SupermuxWorkspaceActivityDTO?
    /// Whether the workspace has unread activity on the Mac.
    public let hasUnread: Bool
    /// The workspace's git branch (the mac row's monospaced subtitle), when
    /// the Mac reported one.
    public let branch: String?
    /// The workspace branch's PR badge, when the Mac reported one (cmux's own
    /// per-workspace probe — the same badge the mac row shows).
    public let pullRequest: SupermuxPullRequestBadgeSnapshot?
    /// Whether this workspace hosts its project's active run command (the mac
    /// row's green play indicator). Stamped by the section model from the
    /// run store's `run.state` rows; `false` when unknown.
    public let isRunning: Bool

    /// Memberwise initializer.
    /// - Parameters:
    ///   - id: The workspace's UI row identifier.
    ///   - remoteID: The Mac-local workspace id; defaults to `id`.
    ///   - projectID: The owning project's UUID string.
    ///   - name: The workspace's display name.
    ///   - activity: The workspace's agent activity, if any.
    ///   - hasUnread: Whether the workspace has unread activity.
    ///   - branch: The workspace's git branch, if known.
    ///   - pullRequest: The branch's PR badge, if known.
    ///   - isRunning: Whether the project's run command runs here.
    public init(
        id: String,
        remoteID: String? = nil,
        projectID: String,
        name: String,
        activity: SupermuxWorkspaceActivityDTO?,
        hasUnread: Bool,
        branch: String? = nil,
        pullRequest: SupermuxPullRequestBadgeSnapshot? = nil,
        isRunning: Bool = false
    ) {
        self.id = id
        self.remoteID = remoteID ?? id
        self.projectID = projectID
        self.name = name
        self.activity = activity
        self.hasUnread = hasUnread
        self.branch = branch
        self.pullRequest = pullRequest
        self.isRunning = isRunning
    }

    /// Projects the shell's workspace previews onto nested-workspace rows,
    /// keeping only project-associated workspaces (in the shell's order).
    /// `isRunning` is always `false` here — the section model stamps it from
    /// the run store when it projects its snapshot.
    /// - Parameter workspaces: The shell's current workspace previews.
    /// - Returns: One row per associated workspace.
    public static func rows(from workspaces: [MobileWorkspacePreview]) -> [SupermuxProjectWorkspaceRowSnapshot] {
        workspaces.compactMap { preview in
            guard let projectID = preview.supermuxProjectID else { return nil }
            let branch = preview.supermuxBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SupermuxProjectWorkspaceRowSnapshot(
                id: preview.id.rawValue,
                remoteID: preview.rpcWorkspaceID.rawValue,
                projectID: projectID,
                name: preview.name,
                activity: preview.supermuxActivity.flatMap(SupermuxWorkspaceActivityDTO.init(rawValue:)),
                hasUnread: preview.hasUnread,
                branch: branch?.isEmpty == false ? branch : nil,
                pullRequest: SupermuxPullRequestBadgeSnapshot(
                    number: preview.supermuxPullRequestNumber,
                    state: preview.supermuxPullRequestState,
                    urlString: preview.supermuxPullRequestURL,
                    isStale: preview.supermuxPullRequestIsStale
                )
            )
        }
    }

    /// A copy of this row with ``isRunning`` set.
    /// - Parameter isRunning: Whether the project's run command runs here.
    public func runningMarked(_ isRunning: Bool) -> SupermuxProjectWorkspaceRowSnapshot {
        SupermuxProjectWorkspaceRowSnapshot(
            id: id,
            remoteID: remoteID,
            projectID: projectID,
            name: name,
            activity: activity,
            hasUnread: hasUnread,
            branch: branch,
            pullRequest: pullRequest,
            isRunning: isRunning
        )
    }

    /// Whether this row hosts the given running workspace id (`run.state`'s
    /// `workspace_id`). UUID strings compare case-insensitively so a
    /// lowercased wire id still matches the Mac's uppercase `uuidString`.
    /// - Parameter runningWorkspaceID: The running workspace id, if any.
    public func hostsRunningWorkspace(_ runningWorkspaceID: String?) -> Bool {
        guard let runningWorkspaceID else { return false }
        return remoteID.caseInsensitiveCompare(runningWorkspaceID) == .orderedSame
    }
}

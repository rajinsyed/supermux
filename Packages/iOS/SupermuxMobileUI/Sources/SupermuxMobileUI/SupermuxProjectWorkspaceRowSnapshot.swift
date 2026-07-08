public import CmuxMobileShellModel
public import Foundation
public import SupermuxMobileCore

/// Immutable value snapshot of one open workspace nested under a project —
/// the phone-side projection of the §6 `supermux_project_id` /
/// `supermux_activity` workspace-list fields. Rendered by the project detail
/// screen's Workspaces section and counted by the project row badge; passed
/// across the shell's `List` boundary as pure values per the repo's
/// snapshot-boundary rule.
public struct SupermuxProjectWorkspaceRowSnapshot: Equatable, Identifiable, Sendable {
    /// The workspace's UI row identifier (the shell's `MobileWorkspacePreview.ID`
    /// raw value) — exactly what the shell's `selectWorkspace` expects back.
    public let id: String
    /// The owning project's UUID string (from `supermux_project_id`).
    public let projectID: String
    /// The workspace's user-facing display name.
    public let name: String
    /// The workspace's agent activity, or `nil` when idle (or the Mac sent an
    /// unknown future spelling — degrade to "no dot", never fail).
    public let activity: SupermuxWorkspaceActivityDTO?
    /// Whether the workspace has unread activity on the Mac.
    public let hasUnread: Bool

    /// Memberwise initializer.
    /// - Parameters:
    ///   - id: The workspace's UI row identifier.
    ///   - projectID: The owning project's UUID string.
    ///   - name: The workspace's display name.
    ///   - activity: The workspace's agent activity, if any.
    ///   - hasUnread: Whether the workspace has unread activity.
    public init(
        id: String,
        projectID: String,
        name: String,
        activity: SupermuxWorkspaceActivityDTO?,
        hasUnread: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.activity = activity
        self.hasUnread = hasUnread
    }

    /// Projects the shell's workspace previews onto nested-workspace rows,
    /// keeping only project-associated workspaces (in the shell's order).
    /// - Parameter workspaces: The shell's current workspace previews.
    /// - Returns: One row per associated workspace.
    public static func rows(from workspaces: [MobileWorkspacePreview]) -> [SupermuxProjectWorkspaceRowSnapshot] {
        workspaces.compactMap { preview in
            guard let projectID = preview.supermuxProjectID else { return nil }
            return SupermuxProjectWorkspaceRowSnapshot(
                id: preview.id.rawValue,
                projectID: projectID,
                name: preview.name,
                activity: preview.supermuxActivity.flatMap(SupermuxWorkspaceActivityDTO.init(rawValue:)),
                hasUnread: preview.hasUnread
            )
        }
    }
}

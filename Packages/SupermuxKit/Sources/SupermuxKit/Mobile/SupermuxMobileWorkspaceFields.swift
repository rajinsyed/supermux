public import Foundation
public import SupermuxMobileCore

extension SupermuxWorkspaceActivity {
    /// The wire spelling of this activity for the mobile workspace-list
    /// payload, or `nil` for ``idle`` (an idle workspace omits the
    /// `supermux_activity` field entirely rather than sending "idle").
    public var mobileWireDTO: SupermuxWorkspaceActivityDTO? {
        switch self {
        case .idle: nil
        case .working: .working
        case .needsInput: .needsInput
        case .ready: .ready
        }
    }
}

/// Pure core of the mobile workspace-list augmenter: computes the additive
/// `supermux_project_id` / `supermux_activity` / `supermux_branch` /
/// `supermux_pull_request` fields the fork merges into each `workspace.list`
/// entry (architecture §6).
///
/// Association resolution goes through the SAME
/// ``SupermuxWorkspaceAssociationStore/projectId(forWorkspace:directory:in:)``
/// the Mac sidebar nests by, and the activity/branch/PR values are exactly
/// what the sidebar's nested workspace row renders at SEND time (the
/// app-target adapter feeds them from `SupermuxWorkspaceActivityResolver`,
/// `Workspace.supermuxSidebarBranch`, and cmux's per-workspace PR probe) —
/// one source, never a re-derivation. Freshness caveat: no fork observer
/// pokes on branch/PR-only mutations yet, so the phone sees a branch/PR
/// change on the next `workspace.updated` poke or list refetch.
///
/// Activity travels for every workspace so the phone's global list has parity
/// with the Mac sidebar. Project id, branch, and pull request remain gated on
/// project association; an associated-but-idle workspace carries the project id
/// alone, while an unassociated idle workspace carries no fields.
@MainActor
public enum SupermuxMobileWorkspaceFields {
    /// Wire key of the owning project's UUID string.
    public static let projectIDKey = "supermux_project_id"
    /// Wire key of the agent-activity raw value (`working` / `needs_input` /
    /// `ready`).
    public static let activityKey = "supermux_activity"
    /// Wire key of the workspace's git branch (the mac row's subtitle).
    public static let branchKey = "supermux_branch"
    /// Wire key of the workspace branch's pull request, encoded as the SAME
    /// ``SupermuxPullRequestDTO`` object shape the worktree DTO carries
    /// (`{number, state, url[, title]}`), so the phone's badge mapping is
    /// shared between worktree rows and nested workspace rows.
    public static let pullRequestKey = "supermux_pull_request"
    /// Wire key of the workspace's unread notification count, which lets the
    /// phone's badge show the Mac's numeral instead of a countless dot.
    ///
    /// Unlike activity, this field is NOT produced by ``fields(_:)``: unread is
    /// a cmux concept sourced from the notification store, so the two transports
    /// set it themselves next to their `augment` call. The key still lives here
    /// so all three spellings (one sender per transport, two decoders) stay
    /// anchored to one constant — a typo would decode as permanently-nil and
    /// look exactly like "paired with upstream cmux".
    public static let unreadCountKey = "supermux_unread_count"
    /// Wire key of pane ids whose Mac notification indicator is visible.
    ///
    /// A supporting Supermux Mac always sends this key, including an empty array,
    /// so the phone can distinguish exact pane state from an older host that only
    /// supports workspace-wide unread state.
    public static let unreadPanelIDsKey = "supermux_unread_panel_ids"

    /// Computes the additive fields for one workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace's stable id.
    ///   - directory: The workspace's current directory (for the durable
    ///     directory / worktree-dir association signals).
    ///   - activity: The workspace's resolved agent activity.
    ///   - branch: The branch the mac sidebar row shows
    ///     (`Workspace.supermuxSidebarBranch`); blank/nil is omitted.
    ///   - pullRequest: The workspace branch's PR as the mac row shows it
    ///     (cmux's per-workspace probe, already gated by the host's PR
    ///     polling settings); `nil` is omitted.
    ///   - projects: All registered projects.
    ///   - associations: The app-wide workspace→project association store.
    /// - Returns: The fields to merge into the workspace payload. Active global
    ///   workspaces carry activity without a project id; idle global workspaces
    ///   return an empty dictionary.
    public static func fields(
        workspaceID: UUID,
        directory: String?,
        activity: SupermuxWorkspaceActivity,
        branch: String? = nil,
        pullRequest: SupermuxPullRequest? = nil,
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let dto = activity.mobileWireDTO {
            fields[activityKey] = dto.rawValue
        }
        guard let projectID = associations.projectId(
            forWorkspace: workspaceID,
            directory: directory,
            in: projects
        ) else {
            return fields
        }
        fields[projectIDKey] = projectID.uuidString
        if let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            fields[branchKey] = branch
        }
        // Encoding a 3-field value type cannot realistically fail; `try?`
        // degrades a hypothetical failure to "no badge" instead of dropping
        // the whole workspace entry.
        if let pullRequest,
           let encoded = try? SupermuxWireJSON().dictionary(
               from: SupermuxPullRequestDTO(pullRequest: pullRequest)
           ) {
            fields[pullRequestKey] = encoded
        }
        return fields
    }
}

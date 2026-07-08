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
/// `supermux_project_id` / `supermux_activity` fields the fork merges into
/// each `workspace.list` entry (architecture §6).
///
/// Association resolution goes through the SAME
/// ``SupermuxWorkspaceAssociationStore/projectId(forWorkspace:directory:in:)``
/// the Mac sidebar nests by, and the activity value is the resolved
/// ``SupermuxWorkspaceActivity`` the sidebar indicator shows (the app-target
/// adapter feeds it from `SupermuxWorkspaceActivityResolver`), so the phone
/// and the sidebar can never disagree.
///
/// Both fields travel ONLY for project-associated workspaces (the validation
/// contract's "workspaces with no association carry neither field"); an
/// associated-but-idle workspace carries the project id alone.
@MainActor
public enum SupermuxMobileWorkspaceFields {
    /// Wire key of the owning project's UUID string.
    public static let projectIDKey = "supermux_project_id"
    /// Wire key of the agent-activity raw value (`working` / `needs_input` /
    /// `ready`).
    public static let activityKey = "supermux_activity"

    /// Computes the additive fields for one workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace's stable id.
    ///   - directory: The workspace's current directory (for the durable
    ///     directory / worktree-dir association signals).
    ///   - activity: The workspace's resolved agent activity.
    ///   - projects: All registered projects.
    ///   - associations: The app-wide workspace→project association store.
    /// - Returns: The fields to merge into the workspace payload; empty when
    ///   the workspace is not associated to any project.
    public static func fields(
        workspaceID: UUID,
        directory: String?,
        activity: SupermuxWorkspaceActivity,
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> [String: Any] {
        guard let projectID = associations.projectId(
            forWorkspace: workspaceID,
            directory: directory,
            in: projects
        ) else {
            return [:]
        }
        var fields: [String: Any] = [projectIDKey: projectID.uuidString]
        if let dto = activity.mobileWireDTO {
            fields[activityKey] = dto.rawValue
        }
        return fields
    }
}

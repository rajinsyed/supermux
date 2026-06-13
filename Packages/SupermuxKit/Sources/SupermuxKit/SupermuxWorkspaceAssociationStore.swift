public import Foundation
public import Observation

/// Resolves which project a workspace nests under in the sidebar, combining a
/// fast session-scoped link with a durable, directory-keyed one.
///
/// cmux gives each live `Workspace` a fresh `UUID` per launch (session restore
/// does not preserve it), so the workspace-id → project map here is necessarily
/// **in-memory and session-scoped**. To survive restarts the store also writes
/// through to a ``SupermuxDirectoryAssociationPersisting`` backend keyed by the
/// workspace's directory, which cmux *does* restore. That covers a project's
/// main workspace, which sits at the project root (not in a worktrees dir) and
/// would otherwise have no durable nesting signal. Worktree workspaces still
/// nest structurally by directory (``SupermuxProjectMatcher/projectOwningWorktree(for:in:)``).
///
/// The durable link is a project-level fact, so closing a workspace only drops
/// its session entry here; the directory link lives until its project is
/// removed. Closing a project's main workspace therefore does not un-nest a
/// still-open sibling at the same directory, and a cancelled close re-nests via
/// the durable link.
///
/// The net rule the user wants: a workspace is "under a project" only when you
/// opened it from that project (remembered across restarts via its directory)
/// or it physically lives in the project's worktrees dir — never merely because
/// it inherited a directory inside a project.
@MainActor
@Observable
public final class SupermuxWorkspaceAssociationStore {
    /// workspace id → owning project id, for workspaces opened from a project
    /// during this app session.
    private var associations: [UUID: UUID] = [:]
    @ObservationIgnored private let worktreeMatcher = SupermuxProjectMatcher()
    /// Durable directory→project backend, consulted across restarts. Weak: the
    /// backend (the projects model) outlives this store and owns persistence.
    @ObservationIgnored private weak var persistence: (any SupermuxDirectoryAssociationPersisting)?

    /// Creates a store.
    /// - Parameter persistence: Durable directory-link backend. `nil` keeps the
    ///   store purely session-scoped (used by focused unit tests).
    public init(persistence: (any SupermuxDirectoryAssociationPersisting)? = nil) {
        self.persistence = persistence
    }

    /// Records that `workspaceId` was opened from `projectId`, durably linking
    /// its `directory` so the workspace re-nests after a restart.
    /// - Parameters:
    ///   - workspaceId: The opened workspace.
    ///   - projectId: The project it was launched from.
    ///   - directory: The workspace's directory, for the durable link. Pass
    ///     `nil` to record only the session link.
    public func associate(workspaceId: UUID, projectId: UUID, directory: String? = nil) {
        associations[workspaceId] = projectId
        if let directory {
            persistence?.associateDirectory(directory, with: projectId)
        }
    }

    /// Forgets a workspace's session association (e.g. when it closes). The
    /// durable directory link is intentionally left intact — it is a
    /// project-level fact cleared only when the project is removed. Harmless if
    /// the workspace was never associated.
    /// - Parameter workspaceId: The workspace to forget.
    public func forget(workspaceId: UUID) {
        associations.removeValue(forKey: workspaceId)
    }

    /// Resolves which project a workspace should nest under, or `nil` to keep
    /// it standalone in the flat list.
    ///
    /// Resolution order: the current session's explicit link wins; then the
    /// durable directory link (so a restored main workspace re-nests); then a
    /// worktree directory match. A link to a project that no longer exists is
    /// ignored.
    /// - Parameters:
    ///   - id: The workspace id.
    ///   - directory: The workspace's current directory.
    ///   - projects: All registered projects.
    /// - Returns: The owning project id, or `nil` when standalone.
    public func projectId(forWorkspace id: UUID, directory: String?, in projects: [SupermuxProject]) -> UUID? {
        if let projectId = associations[id], projects.contains(where: { $0.id == projectId }) {
            return projectId
        }
        if let directory,
           let projectId = persistence?.directoryAssociations[SupermuxProjectMatcher.normalizedDirectory(directory)],
           projects.contains(where: { $0.id == projectId }) {
            return projectId
        }
        return worktreeMatcher.projectOwningWorktree(for: directory, in: projects)?.id
    }
}

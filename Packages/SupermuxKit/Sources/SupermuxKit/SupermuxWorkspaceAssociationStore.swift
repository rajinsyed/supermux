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
    /// Monotonic revision of the association state, bumped by every effective
    /// mutation (session links, standalone markings, pruning, and durable
    /// directory writes routed through ``associate``). SwiftUI bodies that
    /// cache resolution results (the flat-list filter) read this once per pass
    /// so they re-render when associations change *without* a paired
    /// `TabManager` publish — e.g. opening the already-selected workspace from
    /// a project row, which associates but no-ops the selection.
    public private(set) var revision = 0
    /// workspace id → owning project id, for workspaces opened from a project
    /// during this app session. Stays observation-tracked (alongside
    /// ``revision``) so bodies that resolve `projectId` directly — the Projects
    /// section grouping — keep their own dependency on the maps.
    private var associations: [UUID: UUID] = [:]
    /// Workspaces explicitly created via cmux's normal new-workspace flow
    /// (the `+` button / ⌘T / surface tab bar), which must stay standalone in
    /// the flat list even when their inherited directory happens to sit at a
    /// project root or inside a worktrees dir. This enforces the store's stated
    /// rule ("workspaces created via cmux's normal flow stay standalone") for
    /// the durable-directory and worktree-match cases, which key off directory
    /// alone and would otherwise re-capture such a workspace. Session-scoped:
    /// after a restart the set is empty, so a restored project main/worktree
    /// re-nests by directory as before. Cleared by ``associate`` (a later
    /// project-open wins) and ``forget``.
    private var standaloneIds: Set<UUID> = []
    @ObservationIgnored private let worktreeMatcher = SupermuxProjectMatcher()
    /// Durable directory→project backend, consulted across restarts. Weak: the
    /// backend (the projects model) outlives this store and owns persistence.
    @ObservationIgnored private weak var persistence: (any SupermuxDirectoryAssociationPersisting)?

    /// The durable directory→project map, forwarded verbatim from the
    /// persistence backend (`[:]` when none is wired).
    ///
    /// The sidebar's project-resolution cache compares this map *by value* on
    /// every pass: the backend can replace it without routing through this
    /// store — a sibling-build `adopt()` fold-in or `performLoad`'s actor-hop
    /// completion — so ``revision`` alone cannot signal those changes. Reading
    /// it inside a SwiftUI body also registers an Observation dependency on
    /// the backend's `directoryAssociations` (the projects model is
    /// `@Observable`), so the sidebar re-renders on such direct mutations even
    /// without a paired `TabManager` publish. Steady-state comparison cost is
    /// the identical-COW-buffer `==` fast path — the backend only reassigns
    /// the map when its contents actually change.
    public var durableDirectoryAssociations: [String: UUID] {
        persistence?.directoryAssociations ?? [:]
    }

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
        // Opening from a project overrides any earlier standalone marking
        // (e.g. the workspace was created by cmux's `+` flow, then routed
        // through the project opener).
        standaloneIds.remove(workspaceId)
        associations[workspaceId] = projectId
        if let directory {
            persistence?.associateDirectory(directory, with: projectId)
        }
        // Unconditional: a durable directory write can change *another*
        // workspace's resolution even when this workspace's link is unchanged.
        revision &+= 1
    }

    /// Marks a workspace as explicitly standalone, so it never nests under a
    /// project even if its directory matches one. Called for every workspace
    /// created through cmux's normal new-workspace flow; the project opener
    /// clears it via ``associate`` for project-originated opens.
    /// - Parameter workspaceId: The workspace to keep standalone.
    public func markStandalone(workspaceId: UUID) {
        if standaloneIds.insert(workspaceId).inserted {
            revision &+= 1
        }
    }

    /// Forgets a workspace's session association (e.g. when it closes). The
    /// durable directory link is intentionally left intact — it is a
    /// project-level fact cleared only when the project is removed. Harmless if
    /// the workspace was never associated.
    /// - Parameter workspaceId: The workspace to forget.
    public func forget(workspaceId: UUID) {
        let removedAssociation = associations.removeValue(forKey: workspaceId) != nil
        let removedStandalone = standaloneIds.remove(workspaceId) != nil
        if removedAssociation || removedStandalone {
            revision &+= 1
        }
    }

    /// Drops session entries for workspaces that are no longer alive anywhere
    /// in the app. Covers wholesale teardown paths — window close, session
    /// restore releasing pre-restore workspaces — where the per-workspace
    /// close path (and its ``forget(workspaceId:)``) never runs, so entries
    /// would otherwise accumulate for the process lifetime in this app-global
    /// store. Durable directory links are untouched.
    ///
    /// Callers MUST pass the union of workspace ids across *all* windows,
    /// including any closed-but-recoverable windows whose workspaces can be
    /// revived with the same ids — pruning against a single window's tab list
    /// would strip other windows' associations and standalone markings.
    /// - Parameter liveWorkspaceIds: Every workspace id still alive (or
    ///   revivable) in the app.
    public func prune(retainingWorkspaceIds liveWorkspaceIds: Set<UUID>) {
        let countsBefore = (associations.count, standaloneIds.count)
        associations = associations.filter { liveWorkspaceIds.contains($0.key) }
        standaloneIds.formIntersection(liveWorkspaceIds)
        if countsBefore != (associations.count, standaloneIds.count) {
            revision &+= 1
        }
    }

    /// Resolves which project a workspace should nest under, or `nil` to keep
    /// it standalone in the flat list.
    ///
    /// Resolution order: an explicit standalone marking wins (kept in the flat
    /// list); then the current session's explicit link; then the durable
    /// directory link (so a restored main workspace re-nests); then a worktree
    /// directory match. A link to a project that no longer exists is ignored.
    /// - Parameters:
    ///   - id: The workspace id.
    ///   - directory: The workspace's current directory.
    ///   - projects: All registered projects.
    /// - Returns: The owning project id, or `nil` when standalone.
    public func projectId(forWorkspace id: UUID, directory: String?, in projects: [SupermuxProject]) -> UUID? {
        // An explicitly standalone workspace stays in the flat list regardless
        // of its directory — checked before the directory-based links so a `+`
        // workspace inheriting a project/worktree directory is not re-captured.
        if standaloneIds.contains(id) {
            return nil
        }
        if let projectId = associations[id], projects.contains(where: { $0.id == projectId }) {
            return projectId
        }
        guard let directory else { return nil }
        // Normalize once and share it between the durable-link lookup and the
        // worktree match — both key off the same canonical form.
        let normalized = SupermuxProjectMatcher.normalizedDirectory(directory)
        if let projectId = persistence?.directoryAssociations[normalized],
           projects.contains(where: { $0.id == projectId }) {
            return projectId
        }
        return worktreeMatcher.projectOwningWorktree(forNormalizedDirectory: normalized, in: projects)?.id
    }
}

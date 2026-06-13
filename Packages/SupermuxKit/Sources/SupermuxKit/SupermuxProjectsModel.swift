public import Foundation
public import Observation

/// Main-actor domain model behind the supermux Projects sidebar section.
///
/// Owns the in-memory project list, mirrors it through
/// ``SupermuxProjectStore``, and orchestrates worktree operations through
/// ``SupermuxGitWorktreeService``. Views observe this model; it performs no
/// I/O on the main thread beyond dispatching to the underlying actors.
@MainActor
@Observable
public final class SupermuxProjectsModel {
    /// Registered projects in sidebar order.
    public private(set) var projects: [SupermuxProject] = []
    /// Discovered worktrees per project, refreshed on demand.
    public private(set) var worktreesByProjectId: [UUID: [SupermuxProjectWorktree]] = [:]
    /// Projects whose worktree rows are expanded in the sidebar.
    public var expandedProjectIds: Set<UUID> = []
    /// Whether the whole Projects section is collapsed.
    public var isSectionCollapsed: Bool = false {
        didSet {
            guard oldValue != isSectionCollapsed, hasLoaded else { return }
            let collapsed = isSectionCollapsed
            persist { $0.isSectionCollapsed = collapsed }
        }
    }
    /// The most recent persistence or git error, for UI display.
    public private(set) var lastError: String?

    private let store: SupermuxProjectStore
    private let worktreeService: SupermuxGitWorktreeService
    private var hasLoaded = false
    /// Serializes persistence so rapid mutations are written in call order.
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    /// Creates the model.
    /// - Parameters:
    ///   - store: Projects persistence.
    ///   - worktreeService: Git worktree operations.
    public init(store: SupermuxProjectStore, worktreeService: SupermuxGitWorktreeService) {
        self.store = store
        self.worktreeService = worktreeService
    }

    /// Loads persisted projects once; later calls are no-ops.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        let file = await store.load()
        projects = file.projects
        isSectionCollapsed = file.isSectionCollapsed
        hasLoaded = true
        for project in projects {
            await refreshWorktrees(for: project.id)
        }
    }

    /// Registers a folder as a project and returns the new record.
    ///
    /// The display name defaults to the folder basename; when the folder is a
    /// git repository the current branch is captured as the default base.
    /// - Parameter rootPath: Absolute folder path.
    /// - Returns: The created project, or the existing one when the path is
    ///   already registered.
    @discardableResult
    public func addProject(rootPath: String) async -> SupermuxProject {
        let normalized = (rootPath as NSString).standardizingPath
        if let existing = projects.first(where: { $0.rootPath == normalized }) {
            return existing
        }
        var project = SupermuxProject(
            name: (normalized as NSString).lastPathComponent,
            rootPath: normalized
        )
        if await worktreeService.isGitRepository(at: normalized) {
            project.defaultBranch = await worktreeService.currentBranch(repoRoot: normalized)
        }
        projects.append(project)
        let snapshot = projects
        persist { $0.projects = snapshot }
        await refreshWorktrees(for: project.id)
        return project
    }

    /// Replaces a project record (rename, recolor, settings edit).
    /// - Parameter project: Updated record; matched by ``SupermuxProject/id``.
    public func updateProject(_ project: SupermuxProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        let snapshot = projects
        persist { $0.projects = snapshot }
    }

    /// Unregisters a project. Worktrees and the repository are left on disk.
    /// - Parameter id: Project to remove.
    public func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        worktreesByProjectId[id] = nil
        expandedProjectIds.remove(id)
        let snapshot = projects
        persist { $0.projects = snapshot }
    }

    /// Stamps the project as opened now (for recency displays).
    /// - Parameter id: Project that was opened.
    public func noteOpened(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].lastOpenedAt = Date()
        let snapshot = projects
        persist { $0.projects = snapshot }
    }

    /// Re-reads the project's worktrees from git.
    /// - Parameter projectId: Project to refresh.
    public func refreshWorktrees(for projectId: UUID) async {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        do {
            worktreesByProjectId[projectId] = try await worktreeService.listWorktrees(for: project)
        } catch {
            // Non-git projects simply have no worktrees; real git failures
            // surface when the user performs an explicit worktree action.
            worktreesByProjectId[projectId] = []
        }
    }

    /// Creates a worktree and refreshes the project's worktree list.
    /// - Parameters:
    ///   - projectId: Owning project.
    ///   - branchName: Raw branch name input.
    ///   - baseBranch: Optional base branch override.
    /// - Returns: The created worktree.
    /// - Throws: ``SupermuxGitError`` when git fails.
    public func createWorktree(
        projectId: UUID,
        branchName: String,
        baseBranch: String?
    ) async throws -> SupermuxProjectWorktree {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw SupermuxGitError.notAGitRepository(path: "")
        }
        let trimmedBase = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktree = try await worktreeService.createWorktree(
            project: project,
            requestedBranch: branchName,
            baseBranch: (trimmedBase?.isEmpty ?? true) ? nil : trimmedBase
        )
        await refreshWorktrees(for: projectId)
        expandedProjectIds.insert(projectId)
        return worktree
    }

    /// Removes a worktree and refreshes the project's worktree list.
    /// - Parameters:
    ///   - worktree: Worktree to remove.
    ///   - projectId: Owning project.
    ///   - force: Remove despite uncommitted changes.
    ///   - deleteBranch: Also delete the local branch.
    /// - Throws: ``SupermuxGitError`` when git fails.
    public func removeWorktree(
        _ worktree: SupermuxProjectWorktree,
        projectId: UUID,
        force: Bool,
        deleteBranch: Bool
    ) async throws {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        try await worktreeService.removeWorktree(
            worktree,
            project: project,
            force: force,
            deleteBranch: deleteBranch
        )
        await refreshWorktrees(for: projectId)
    }

    /// Local branches of the project's repository (for base-branch pickers).
    /// - Parameter projectId: Project to inspect.
    public func localBranches(projectId: UUID) async -> [String] {
        guard let project = projects.first(where: { $0.id == projectId }) else { return [] }
        return await worktreeService.localBranches(repoRoot: project.rootPath)
    }

    private func persist(_ mutate: @escaping @Sendable (inout SupermuxProjectsFile) -> Void) {
        let store = self.store
        // Chain persists so two rapid mutations apply in call order (each passes
        // a whole snapshot, so out-of-order writes would resurrect stale state).
        // This is a @MainActor method, so the Task body and the catch run on the
        // main actor — no extra MainActor.run hop is needed.
        let previous = persistTask
        persistTask = Task { [weak self] in
            await previous?.value
            do {
                try await store.update(mutate)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }
}

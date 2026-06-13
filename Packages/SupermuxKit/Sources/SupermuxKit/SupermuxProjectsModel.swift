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
public final class SupermuxProjectsModel: SupermuxDirectoryAssociationPersisting {
    /// Registered projects in sidebar order.
    public private(set) var projects: [SupermuxProject] = []
    /// Discovered worktrees per project, refreshed on demand.
    public private(set) var worktreesByProjectId: [UUID: [SupermuxProjectWorktree]] = [:]
    /// Global terminal-presets-bar entries in bar order. Seeded with
    /// ``SupermuxTerminalPreset/defaults`` the first time the model loads a
    /// document that has never carried presets.
    public private(set) var presets: [SupermuxTerminalPreset] = []
    /// Durable directory→project links (see
    /// ``SupermuxDirectoryAssociationPersisting``), keyed by normalized path.
    /// Reloaded from disk on launch so a project's main workspace nests again.
    public private(set) var directoryAssociations: [String: UUID] = [:]
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
    /// Matches a directory against a project's worktrees dir; used to skip
    /// durable links for worktree paths (they already nest structurally).
    @ObservationIgnored private let worktreeMatcher = SupermuxProjectMatcher()
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
        // Restore durable directory→project links, dropping any whose project no
        // longer exists so the map can't accumulate dead entries across launches.
        let validProjectIds = Set(projects.map(\.id))
        let storedAssociations = file.directoryAssociations ?? [:]
        let prunedAssociations = storedAssociations.filter { validProjectIds.contains($0.value) }
        directoryAssociations = prunedAssociations
        if prunedAssociations.count != storedAssociations.count {
            persistDirectoryAssociations()
        }
        // Seed default presets the first time a document without them loads, and
        // write them back so the seed is stable. An explicitly empty array means
        // the user cleared the bar and is preserved untouched.
        if let storedPresets = file.presets {
            presets = storedPresets
        } else {
            presets = SupermuxTerminalPreset.defaults
            let seeded = presets
            persist { $0.presets = seeded }
        }
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

    /// Reorders `draggedId` so it sits next to `targetId` in sidebar order,
    /// matching the direction of the drag (after the target when moving down,
    /// before it when moving up). Used by sidebar drag-reorder and the
    /// Move Up / Move Down context-menu actions.
    ///
    /// No-op when either id is unknown or `draggedId == targetId`, so callers
    /// can invoke it freely without bounds checks.
    /// - Parameters:
    ///   - draggedId: Project being moved.
    ///   - targetId: Project the dragged row is hovering over.
    public func moveProject(_ draggedId: UUID, over targetId: UUID) {
        guard draggedId != targetId,
              let from = projects.firstIndex(where: { $0.id == draggedId }),
              let to = projects.firstIndex(where: { $0.id == targetId }) else { return }
        var reordered = projects
        let moved = reordered.remove(at: from)
        // After removal the target may have shifted; locate it again and insert
        // after it when dragging downward, before it when dragging upward.
        let targetIndex = reordered.firstIndex(where: { $0.id == targetId }) ?? reordered.endIndex
        reordered.insert(moved, at: to > from ? targetIndex + 1 : targetIndex)
        projects = reordered
        let snapshot = projects
        persist { $0.projects = snapshot }
    }

    /// Unregisters a project. Worktrees and the repository are left on disk.
    /// - Parameter id: Project to remove.
    public func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        worktreesByProjectId[id] = nil
        expandedProjectIds.remove(id)
        // Drop durable links pointing at the removed project so they can't
        // re-nest a stale workspace under a project that no longer exists.
        directoryAssociations = directoryAssociations.filter { $0.value != id }
        let projectsSnapshot = projects
        let associationsSnapshot = directoryAssociations
        persist {
            $0.projects = projectsSnapshot
            $0.directoryAssociations = associationsSnapshot.isEmpty ? nil : associationsSnapshot
        }
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

    // MARK: - Terminal presets

    /// Appends a new launchable preset to the bar.
    /// - Parameter preset: The preset to add (kept even if not yet launchable
    ///   so the editor can fill it in).
    public func addPreset(_ preset: SupermuxTerminalPreset) {
        presets.append(preset)
        persistPresets()
    }

    /// Replaces a preset by ``SupermuxTerminalPreset/id``; no-op when unknown.
    /// - Parameter preset: Updated record.
    public func updatePreset(_ preset: SupermuxTerminalPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persistPresets()
    }

    /// Removes a preset from the bar.
    /// - Parameter id: Preset to remove.
    public func removePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        persistPresets()
    }

    /// Replaces the entire ordered preset list (used by the editor sheet on
    /// save, which owns reordering and field edits in local state).
    /// - Parameter presets: The new ordered list.
    public func setPresets(_ presets: [SupermuxTerminalPreset]) {
        self.presets = presets
        persistPresets()
    }

    /// Restores the bar to ``SupermuxTerminalPreset/defaults``.
    public func resetPresetsToDefaults() {
        presets = SupermuxTerminalPreset.defaults
        persistPresets()
    }

    private func persistPresets() {
        let snapshot = presets
        persist { $0.presets = snapshot }
    }

    // MARK: - Directory associations (SupermuxDirectoryAssociationPersisting)

    public func associateDirectory(_ directory: String, with projectId: UUID) {
        let key = SupermuxProjectMatcher.normalizedDirectory(directory)
        guard !key.isEmpty, directoryAssociations[key] != projectId else { return }
        // Worktree directories nest structurally (``SupermuxProjectMatcher``
        // matches the worktrees dir), so a durable link for them is redundant —
        // and would linger as a stale entry after the worktree is deleted, since
        // links are only cleared on project removal. Persist only links we need:
        // the project's main/root workspace, which has no structural signal.
        guard worktreeMatcher.projectOwningWorktree(for: key, in: projects) == nil else { return }
        directoryAssociations[key] = projectId
        persistDirectoryAssociations()
    }

    private func persistDirectoryAssociations() {
        let snapshot = directoryAssociations
        persist { $0.directoryAssociations = snapshot.isEmpty ? nil : snapshot }
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

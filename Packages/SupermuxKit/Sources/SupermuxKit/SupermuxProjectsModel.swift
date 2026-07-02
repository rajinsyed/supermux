public import Foundation
public import Observation

/// Main-actor domain model behind the supermux Projects sidebar section.
///
/// Owns the in-memory project list, mirrors it through
/// ``SupermuxProjectStore``, and orchestrates worktree operations through
/// ``SupermuxGitWorktreeService``. Views observe this model; it performs no
/// I/O on the main thread beyond dispatching to the underlying actors.
///
/// Persistence contract: every mutation queues a *semantic* closure that edits
/// the freshly re-read on-disk document (append/replace/remove by id) — never
/// a wholesale snapshot assignment — because the projects file is shared with
/// concurrently running stable/nightly/DEV builds whose edits a stale snapshot
/// would clobber. After the last queued persist, in-memory state converges
/// with the document returned by the store.
@MainActor
@Observable
public final class SupermuxProjectsModel: SupermuxDirectoryAssociationPersisting {
    /// Registered projects in sidebar order.
    public private(set) var projects: [SupermuxProject] = []
    /// Discovered worktrees per project, refreshed on demand.
    public private(set) var worktreesByProjectId: [UUID: [SupermuxProjectWorktree]] = [:]
    /// Global terminal-presets-bar entries in bar order. Seeded with
    /// ``SupermuxTerminalPreset/defaults`` the first time the model loads a
    /// document that has never carried presets. Setter is internal for the
    /// presets extension (`SupermuxProjectsModel+Presets.swift`).
    public internal(set) var presets: [SupermuxTerminalPreset] = []
    /// Durable directory→project links (see
    /// ``SupermuxDirectoryAssociationPersisting``), keyed by normalized path.
    /// Reloaded from disk on launch so a project's main workspace nests again.
    public internal(set) var directoryAssociations: [String: UUID] = [:]
    /// Projects whose worktree rows are expanded in the sidebar.
    public var expandedProjectIds: Set<UUID> = []
    /// Whether the whole Projects section is collapsed.
    public var isSectionCollapsed: Bool = false {
        didSet {
            guard oldValue != isSectionCollapsed, hasLoaded, !isAdoptingPersistedState else { return }
            let collapsed = isSectionCollapsed
            persist { $0.isSectionCollapsed = collapsed }
        }
    }
    /// The most recent persistence error, for UI display. Cleared by the next
    /// successful persist.
    public private(set) var lastError: String?
    /// Set when the launch load fell back to an empty document (corrupt file
    /// quarantined to a backup, or an unreadable file), for UI display. Sticky
    /// for the session — unlike ``lastError`` it is not cleared by a later
    /// successful persist, so the "your list was reset, backup at …" notice
    /// survives the persists that routinely follow a load.
    public private(set) var loadFailureNotice: String?

    private let store: SupermuxProjectStore
    private let worktreeService: SupermuxGitWorktreeService
    /// Optional AI branch-name suggester. When `nil`, blank branch fields fall
    /// back to the worktree service's random-name behavior.
    @ObservationIgnored private let branchNamer: (any SupermuxAIBranchNaming)?
    private var hasLoaded = false
    /// The in-flight (or completed) load; concurrent ``loadIfNeeded()`` callers
    /// await this single task instead of re-running the load body.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// How many times the full load body has run. Test hook pinning that
    /// concurrent ``loadIfNeeded()`` callers share one load.
    @ObservationIgnored private(set) var loadRunCount = 0
    /// Matches a directory against a project's worktrees dir; used to skip
    /// durable links for worktree paths (they already nest structurally).
    /// Internal for the presets/associations extension.
    @ObservationIgnored let worktreeMatcher = SupermuxProjectMatcher()
    /// Reads a project's `.supermux`/`.superset` `config.json`; applied on add
    /// and on load so a repo-shipped config drives setup/teardown/run/actions.
    @ObservationIgnored private let configLoader = SupermuxProjectConfigLoader()
    /// Serializes persistence so rapid mutations are written in call order.
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// Monotonic id of the newest queued persist; the matching task is the
    /// chain tail and the only one allowed to fold disk state back in.
    @ObservationIgnored private var persistGeneration = 0
    /// Suppresses the `isSectionCollapsed` didSet persist while ``adopt(_:)``
    /// assigns the already-persisted value.
    @ObservationIgnored private var isAdoptingPersistedState = false

    /// Creates the model.
    /// - Parameters:
    ///   - store: Projects persistence.
    ///   - worktreeService: Git worktree operations.
    ///   - branchNamer: Optional AI branch-name suggester used by
    ///     ``suggestBranchName(forWorkspaceName:)``.
    public init(
        store: SupermuxProjectStore,
        worktreeService: SupermuxGitWorktreeService,
        branchNamer: (any SupermuxAIBranchNaming)? = nil
    ) {
        self.store = store
        self.worktreeService = worktreeService
        self.branchNamer = branchNamer
    }

    /// Whether AI branch naming is wired and a key is configured.
    public func isAIBranchNamingConfigured() async -> Bool {
        await branchNamer?.isConfigured() ?? false
    }

    /// Suggests a git-safe branch name from a workspace description, or `nil`
    /// when AI naming is unavailable or fails. Callers pass the result straight
    /// to ``createWorktree(projectId:branchName:baseBranch:)``, which sanitizes
    /// and deduplicates it again.
    /// - Parameter name: Free-form workspace name typed by the user.
    public func suggestBranchName(forWorkspaceName name: String) async -> String? {
        guard let branchNamer else { return nil }
        return await branchNamer.suggestBranchName(forWorkspaceName: name)
    }

    /// Loads persisted projects once. Concurrent and later callers (the
    /// Projects section mounts once per window) await the same single load.
    public func loadIfNeeded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        loadRunCount += 1
        let file = await store.load()
        projects = file.projects
        isSectionCollapsed = file.isSectionCollapsed
        hasLoaded = true
        // Tell the user when the list was reset because the file was corrupt
        // (with the quarantine backup path) instead of failing silently.
        if let failure = await store.lastLoadFailure {
            loadFailureNotice = Self.message(for: failure)
        }
        // Restore durable directory→project links, dropping any whose project no
        // longer exists so the map can't accumulate dead entries across launches.
        let validProjectIds = Set(projects.map(\.id))
        let storedAssociations = file.directoryAssociations ?? [:]
        let prunedAssociations = storedAssociations.filter { validProjectIds.contains($0.value) }
        directoryAssociations = prunedAssociations
        if prunedAssociations.count != storedAssociations.count {
            // Semantic prune: validity is judged against the projects in the
            // freshly-read document, not this instance's launch snapshot.
            persist { file in
                guard let associations = file.directoryAssociations else { return }
                let valid = Set(file.projects.map(\.id))
                let pruned = associations.filter { valid.contains($0.value) }
                file.directoryAssociations = pruned.isEmpty ? nil : pruned
            }
        }
        // Seed default presets the first time a document without them loads, and
        // write them back so the seed is stable. An explicitly empty array means
        // the user cleared the bar and is preserved untouched.
        if let storedPresets = file.presets {
            presets = storedPresets
        } else {
            presets = SupermuxTerminalPreset.defaults
            let seeded = presets
            persist { $0.presets = $0.presets ?? seeded }
        }
        // Re-import each project's shipped config.json (when present) so a
        // repo's setup/teardown/run/actions stay in sync across launches, then
        // refresh its worktrees — in parallel, so launch time is bounded by the
        // slowest project instead of the sum of one git spawn per project.
        await withTaskGroup(of: Void.self) { group in
            for project in projects {
                let id = project.id
                group.addTask { [weak self] in
                    await self?.importConfig(into: id)
                    await self?.refreshWorktrees(for: id)
                }
            }
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
        if let existing = registeredProject(at: normalized) {
            return existing
        }
        var project = SupermuxProject(
            name: (normalized as NSString).lastPathComponent,
            rootPath: normalized
        )
        if await worktreeService.isGitRepository(at: normalized) {
            project.defaultBranch = await worktreeService.currentBranch(repoRoot: normalized)
        }
        // Re-check after the awaits: the model is main-actor reentrant there,
        // so a concurrent add of the same folder may have registered it.
        if let existing = registeredProject(at: normalized) {
            return existing
        }
        projects.append(project)
        let record = project
        persist { file in
            guard !file.projects.contains(where: { $0.id == record.id || $0.rootPath == record.rootPath }) else { return }
            file.projects.append(record)
        }
        // Pull in a repo-shipped config.json, if any, before opening anything so
        // the project's setup/teardown/run/actions are populated from the start.
        await importConfig(into: project.id)
        await refreshWorktrees(for: project.id)
        return projects.first(where: { $0.id == project.id }) ?? project
    }

    /// The registered project at `normalized`, matched by the exact logical
    /// path or by symlink-resolved form, so the logical and physical spellings
    /// of one folder never register as two projects.
    private func registeredProject(at normalized: String) -> SupermuxProject? {
        if let exact = projects.first(where: { $0.rootPath == normalized }) { return exact }
        let resolved = SupermuxProjectMatcher.resolvedDirectory(normalized)
        return projects.first { SupermuxProjectMatcher.resolvedDirectory($0.rootPath) == resolved }
    }

    /// Imports the project's `config.json` (when present), overwriting its
    /// config-managed fields (setup, teardown, run, actions). A straight
    /// overwrite — `config.json` is the source of truth for those fields — that
    /// no-ops when nothing changed so it never churns persistence.
    /// - Parameter projectId: Project whose config to (re)import.
    private func importConfig(into projectId: UUID) async {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let rootPath = projects[index].rootPath
        let loader = configLoader
        // File I/O off the main actor; the loader is a Sendable value type.
        guard let config = await Task.detached(priority: .utility, operation: {
            loader.load(projectRoot: rootPath)
        }).value else { return }
        // Re-resolve the index after the await — the project may have been
        // removed or reordered while the config was read.
        guard let currentIndex = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let updated = projects[currentIndex].applying(config)
        guard updated != projects[currentIndex] else { return }
        projects[currentIndex] = updated
        persistReplacingProject(updated)
    }

    /// Replaces a project record (rename, recolor, settings edit).
    /// - Parameter project: Updated record; matched by ``SupermuxProject/id``.
    public func updateProject(_ project: SupermuxProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        persistReplacingProject(project)
    }

    private func persistReplacingProject(_ project: SupermuxProject) {
        persist { file in
            guard let i = file.projects.firstIndex(where: { $0.id == project.id }) else { return }
            file.projects[i] = project
        }
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
        guard Self.applyMove(draggedId, over: targetId, in: &projects) else { return }
        // The same relative move re-applies to the freshly-read document, so
        // projects unknown to this instance keep their on-disk positions.
        persist { Self.applyMove(draggedId, over: targetId, in: &$0.projects) }
    }

    /// Applies the relative move in place; returns `false` (untouched array)
    /// when either id is unknown or `draggedId == targetId`.
    @discardableResult
    nonisolated private static func applyMove(_ draggedId: UUID, over targetId: UUID, in projects: inout [SupermuxProject]) -> Bool {
        guard draggedId != targetId,
              let from = projects.firstIndex(where: { $0.id == draggedId }),
              let to = projects.firstIndex(where: { $0.id == targetId }) else { return false }
        let moved = projects.remove(at: from)
        // After removal the target may have shifted; locate it again and insert
        // after it when dragging downward, before it when dragging upward.
        let targetIndex = projects.firstIndex(where: { $0.id == targetId }) ?? projects.endIndex
        projects.insert(moved, at: to > from ? targetIndex + 1 : targetIndex)
        return true
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
        persist { file in
            file.projects.removeAll { $0.id == id }
            if let associations = file.directoryAssociations {
                let remaining = associations.filter { $0.value != id }
                file.directoryAssociations = remaining.isEmpty ? nil : remaining
            }
        }
    }

    /// Stamps the project as opened now (for recency displays).
    /// - Parameter id: Project that was opened.
    public func noteOpened(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        // Capture the date once so the queued persist writes exactly the
        // timestamp memory shows.
        let openedAt = Date()
        projects[index].lastOpenedAt = openedAt
        persist { file in
            guard let i = file.projects.firstIndex(where: { $0.id == id }) else { return }
            file.projects[i].lastOpenedAt = openedAt
        }
    }

    /// Re-reads the project's worktrees from git.
    /// - Parameter projectId: Project to refresh.
    public func refreshWorktrees(for projectId: UUID) async {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        let list: [SupermuxProjectWorktree]
        do {
            list = try await worktreeService.listWorktrees(for: project)
        } catch {
            // Non-git projects simply have no worktrees; real git failures
            // surface when the user performs an explicit worktree action.
            list = []
        }
        if worktreesByProjectId[projectId] != list {
            worktreesByProjectId[projectId] = list
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
        // Pick up any edits to the repo's config.json before creating, so the
        // new worktree's setup script reflects the current source of truth.
        await importConfig(into: projectId)
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
        // Refresh the teardown script from the repo's config.json before removal.
        await importConfig(into: projectId)
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

    // MARK: - Persistence

    /// Queues a semantic mutation of the on-disk document. Internal so the
    /// split-file extension (presets, directory associations) shares this one
    /// persistence path.
    ///
    /// Closures must edit the freshly-read file (append/replace/remove by id),
    /// never assign whole snapshots — the file is shared with concurrently
    /// running builds whose edits a stale snapshot would clobber. Closures
    /// capture value snapshots only (ids, dates, records).
    func persist(_ mutate: @escaping @Sendable (inout SupermuxProjectsFile) -> Void) {
        let store = self.store
        persistGeneration &+= 1
        let generation = persistGeneration
        // Chain persists so rapid mutations apply to the document in call
        // order. This is a @MainActor method, so the Task body runs on the
        // main actor — no extra MainActor.run hop is needed.
        let previous = persistTask
        persistTask = Task { [weak self] in
            await previous?.value
            do {
                let persisted = try await store.update(mutate)
                guard let self else { return }
                if self.lastError != nil { self.lastError = nil }
                // Fold disk truth back in only from the tail of the chain: a
                // mid-chain adopt would transiently revert newer local
                // mutations whose persists are still queued behind this one.
                if generation == self.persistGeneration {
                    self.adopt(persisted)
                }
            } catch {
                self?.lastError = String(
                    format: String(localized: "supermux.projects.saveFailed", defaultValue: "Couldn't save projects: %@"),
                    error.localizedDescription
                )
            }
        }
    }

    /// Converges in-memory state with the post-write on-disk document, folding
    /// in concurrent instances' edits. Worktree lists for projects added by
    /// another instance populate on their next explicit refresh.
    private func adopt(_ file: SupermuxProjectsFile) {
        if projects != file.projects { projects = file.projects }
        if let adoptedPresets = file.presets, adoptedPresets != presets { presets = adoptedPresets }
        let associations = file.directoryAssociations ?? [:]
        if directoryAssociations != associations { directoryAssociations = associations }
        let ids = Set(file.projects.map(\.id))
        let prunedWorktrees = worktreesByProjectId.filter { ids.contains($0.key) }
        if prunedWorktrees.count != worktreesByProjectId.count { worktreesByProjectId = prunedWorktrees }
        if !expandedProjectIds.isSubset(of: ids) { expandedProjectIds.formIntersection(ids) }
        if isSectionCollapsed != file.isSectionCollapsed {
            // Bypass the didSet persist: this value is the persisted one.
            isAdoptingPersistedState = true
            isSectionCollapsed = file.isSectionCollapsed
            isAdoptingPersistedState = false
        }
    }

    private static func message(for failure: SupermuxProjectStore.LoadFailure) -> String {
        switch failure {
        case .corrupted(.some(let backupURL)):
            String(
                format: String(
                    localized: "supermux.projects.corruptReset",
                    defaultValue: "The projects file couldn't be read and was reset. A backup was saved to %@."
                ),
                backupURL.path
            )
        case .corrupted(nil):
            String(
                localized: "supermux.projects.corruptResetNoBackup",
                defaultValue: "The projects file couldn't be read and was reset."
            )
        case .unreadable(let message):
            String(
                format: String(
                    localized: "supermux.projects.loadFailed",
                    defaultValue: "Projects couldn't be loaded: %@"
                ),
                message
            )
        }
    }
}

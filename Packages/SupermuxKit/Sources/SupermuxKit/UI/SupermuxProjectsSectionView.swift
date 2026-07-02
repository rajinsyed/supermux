public import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Deregisters this window's PR-badge client when the section's `@State` is
/// torn down — a whole-window close skips `onDisappear` (see
/// ``SupermuxChangesModel``'s `deinit` for the same pitfall), but `@State`
/// storage is still destroyed, so this token's `deinit` is the backstop that
/// keeps a closed window's paths out of the shared model's prune union and its
/// entry out of the client registry. The section's `onDisappear` still calls
/// ``SupermuxWorktreePullRequestModel/endTracking(client:)`` directly for
/// prompt cleanup; the double call is harmless because `endTracking` treats
/// unknown clients as a no-op.
@MainActor final class SupermuxPullRequestClientToken {
    /// This section's stable client identity with the (possibly shared) model.
    let id = UUID()
    /// The model to deregister from; wired once before the first refresh.
    /// Weak: the token must never keep a host-shared model alive.
    weak var model: SupermuxWorktreePullRequestModel?
    deinit {
        // deinit of a @MainActor class is not MainActor-isolated, so hop via a
        // Task — capturing locals, never `self` (it is being destroyed).
        let model = self.model
        let id = self.id
        Task { @MainActor in model?.endTracking(client: id) }
    }
}

/// The sticky "Projects" section rendered at the top of the cmux sidebar.
///
/// Shows every registered project with quick actions to open it locally or
/// spin up a git worktree, mirroring piggycode's sticky workspaces. The host
/// app supplies a ``SupermuxWorkspaceOpening`` so activating a row opens (or
/// focuses) a real cmux workspace.
public struct SupermuxProjectsSectionView: View {
    // Internal (not private) where the PR-probe extension in
    // `SupermuxProjectsSectionView+PullRequests.swift` needs access.
    @Bindable var model: SupermuxProjectsModel
    private let opener: any SupermuxWorkspaceOpening
    let openWorkspaces: [SupermuxOpenWorkspace]
    private let onSelectWorkspace: (UUID) -> Void
    private let onCloseWorkspace: (UUID) -> Void
    private let onRenameWorkspace: (UUID, String) -> Void
    private let onReorderWorkspace: (UUID, UUID) -> Void
    private let onOpenPullRequest: (URL, UUID?) -> Void
    /// Host-supplied gate/cadence for the worktree PR probe (mirrors cmux's
    /// own PR polling settings). Defaults to enabled at 60s.
    let pullRequestPolling: SupermuxPullRequestPollingPolicy

    /// Resolves pull requests for unopened worktrees (opened ones reuse cmux's
    /// own probe via ``SupermuxOpenWorkspace/pullRequest``). Owned here at the
    /// section level — never by a row — so rows receive immutable PR value
    /// snapshots, preserving the sidebar snapshot boundary. May be a shared,
    /// host-injected instance serving every window (see `init`).
    @State var pullRequestModel: SupermuxWorktreePullRequestModel
    /// This section's stable identity with the (possibly shared) PR model, so
    /// one window's refresh never prunes badges another window still tracks.
    /// A deinit token rather than a bare `UUID` so a whole-window close (which
    /// skips `onDisappear`) still deregisters the client.
    @State var pullRequestClientToken = SupermuxPullRequestClientToken()

    @State private var newWorktreeProject: SupermuxProject?
    @State private var editorProject: SupermuxProject?
    /// In-flight drag-reorder marker (project or nested workspace). A reference
    /// `@Observable`, not value `@State`: writing the dragged id at drag start
    /// must invalidate only the dragged row's dim, never this section's body /
    /// `ForEach` — which would recreate the row mid-gesture and cancel the drag.
    @State private var dragState = SupermuxSidebarDragState()
    /// Clears `dragState` on mouse-up / Escape so an aborted drag (released off
    /// any row) doesn't leave a row stuck dimmed. Mirrors cmux's failsafe.
    @State private var dragFailsafe = SupermuxSidebarDragFailsafe()
    /// Resolves and caches each project's auto-detected logo. Owned above the
    /// project list so rows receive only an immutable `NSImage?` snapshot. May
    /// be a shared, host-injected instance (see `init`) so every window — and
    /// the workspace switcher — reuses one decoded-logo cache.
    @State private var iconStore: SupermuxProjectIconStore
    /// Sidebar font scale (cmux's `sidebar-font-size`); scales the section
    /// header alongside the project rows. `1` at the default size. Internal
    /// (not private) for the header extension in
    /// `SupermuxProjectsSectionView+Header.swift`.
    @Environment(\.supermuxSidebarFontScale) var fontScale

    /// Creates the section.
    /// - Parameters:
    ///   - model: Shared projects model.
    ///   - opener: Host-app workspace opener.
    ///   - openWorkspaces: Snapshot of the host's live workspaces, rendered
    ///     nested under the project each belongs to. Defaults to empty.
    ///   - onSelectWorkspace: Focuses a nested workspace by id.
    ///   - onCloseWorkspace: Closes a nested workspace by id.
    ///   - onRenameWorkspace: Sets a nested workspace's custom title `(id,
    ///     newTitle)` (an empty title clears it, reverting to the process title).
    ///   - onReorderWorkspace: Reorders a nested workspace `(draggedId,
    ///     targetId)` within its project (wired to the host's tab order).
    ///   - onOpenPullRequest: Opens a PR badge's URL; the second argument is
    ///     the open workspace the badge belongs to (`nil` for an unopened
    ///     worktree's badge). Defaults to the system browser; the host
    ///     overrides it to honor cmux's PR-link routing and open the PR in the
    ///     badge's own workspace.
    ///   - pullRequestPolling: Gate + cadence for the worktree PR probe; the
    ///     host derives it from cmux's PR polling settings. Defaults to the
    ///     standalone behavior (enabled, 60s).
    ///   - pullRequestModel: A host-owned PR model shared across windows so one
    ///     poll pass and one repo cache serve every sidebar. Pass a **stable**
    ///     instance (it seeds `@State` on first mount). `nil` (the default)
    ///     keeps a private per-section model.
    ///   - iconStore: A host-owned logo cache shared across windows (and the
    ///     workspace switcher). Same stable-instance contract as
    ///     `pullRequestModel`; `nil` keeps a private per-section store. Note
    ///     the store's `refresh(projects:)` prunes entries missing from the
    ///     passed list, so shared callers must always pass the full project
    ///     list (this section does).
    public init(
        model: SupermuxProjectsModel,
        opener: any SupermuxWorkspaceOpening,
        openWorkspaces: [SupermuxOpenWorkspace] = [],
        onSelectWorkspace: @escaping (UUID) -> Void = { _ in },
        onCloseWorkspace: @escaping (UUID) -> Void = { _ in },
        onRenameWorkspace: @escaping (UUID, String) -> Void = { _, _ in },
        onReorderWorkspace: @escaping (UUID, UUID) -> Void = { _, _ in },
        onOpenPullRequest: @escaping (URL, UUID?) -> Void = { url, _ in _ = NSWorkspace.shared.open(url) },
        pullRequestPolling: SupermuxPullRequestPollingPolicy = SupermuxPullRequestPollingPolicy(),
        pullRequestModel: SupermuxWorktreePullRequestModel? = nil,
        iconStore: SupermuxProjectIconStore? = nil
    ) {
        self.model = model
        self.opener = opener
        self.openWorkspaces = openWorkspaces
        self.onSelectWorkspace = onSelectWorkspace
        self.onCloseWorkspace = onCloseWorkspace
        self.onRenameWorkspace = onRenameWorkspace
        self.onReorderWorkspace = onReorderWorkspace
        self.onOpenPullRequest = onOpenPullRequest
        self.pullRequestPolling = pullRequestPolling
        _pullRequestModel = State(initialValue: pullRequestModel ?? SupermuxWorktreePullRequestModel())
        _iconStore = State(initialValue: iconStore ?? SupermuxProjectIconStore())
    }

    public var body: some View {
        let grouped = workspacesByProject()
        let projects = displayProjects
        VStack(alignment: .leading, spacing: 2) {
            header
            // Persistence problems are otherwise invisible: a sticky "projects
            // file was reset (backup at …)" notice, and the latest save error
            // (cleared automatically by the next successful save). Independent
            // `if`s on purpose: the reset notice is session-sticky, so an
            // `else if` would hide every later save error in exactly the
            // session where the user is rebuilding the list.
            if let notice = model.loadFailureNotice {
                storageNotice(notice)
            }
            if let error = model.lastError {
                storageNotice(error)
            }
            if !model.isSectionCollapsed {
                ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                    SupermuxProjectRowView(
                        project: project,
                        detectedIcon: iconStore.image(for: project.id),
                        worktrees: model.worktreesByProjectId[project.id] ?? [],
                        worktreePullRequests: worktreePullRequests(for: project.id),
                        openWorkspaces: grouped[project.id] ?? [],
                        isExpanded: model.expandedProjectIds.contains(project.id),
                        actions: rowActions(for: project),
                        canMoveUp: index > 0,
                        canMoveDown: index < projects.count - 1,
                        beginDrag: {
                            dragState.draggingProjectId = project.id
                            return NSItemProvider(object: project.id.uuidString as NSString)
                        },
                        dropDelegate: SupermuxProjectDropDelegate(
                            targetProjectId: project.id,
                            draggingProjectId: $dragState.draggingProjectId,
                            // Hover-moves only update the in-memory preview; the
                            // model is reordered (and the projects file written)
                            // once, when the drag ends.
                            move: { dragged, target in
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    dragState.previewProjectMove(
                                        dragged: dragged,
                                        over: target,
                                        baseOrder: model.projects.map(\.id)
                                    )
                                }
                            },
                            end: { dragState.clear() }
                        ),
                        draggingProjectId: $dragState.draggingProjectId,
                        draggingWorkspaceId: $dragState.draggingWorkspaceId
                    )
                }
                if model.projects.isEmpty {
                    emptyHint
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        // A drag released off any row never reaches a `performDrop`, so without
        // this the source row would stay dimmed. The failsafe ends the drag on
        // the next mouse-up or Escape; the deferred end lets a real drop's
        // `performDrop` run first. A release commits the previewed project
        // order — even off-row, the order the user last saw persists (once per
        // drag, not per hovered row) — while Escape cancels and discards it.
        .onAppear {
            dragFailsafe.start(clearing: dragState)
            // Commits a finished drag's previewed order to the model as a
            // single `moveProject` (one reorder + one persist per drag).
            // Captures ONLY the class-reference model, never the view struct:
            // a closure holding the view would also hold its `_dragState`
            // State location, closing a dragState → closure → view → dragState
            // retain cycle that leaks the section's snapshots on teardown.
            dragState.commitProjectOrder = { [model] preview in
                guard let target = SupermuxSidebarDragState.commitTarget(
                    dragged: preview.draggedProjectId,
                    previewOrder: preview.order,
                    currentOrder: model.projects.map(\.id)
                ) else { return }
                model.moveProject(preview.draggedProjectId, over: target)
            }
        }
        .onDisappear {
            dragFailsafe.stop()
            dragState.commitProjectOrder = nil
            // The (possibly shared) PR model prunes badges to the union of all
            // clients' tracked paths, so a torn-down section must deregister —
            // otherwise its paths stay in the union forever and the client
            // registry grows across window open/close cycles. Kept alongside
            // the token's deinit backstop for prompt cleanup; the eventual
            // double endTracking is a no-op for the already-removed client.
            pullRequestModel.endTracking(client: pullRequestClientToken.id)
        }
        .task { await model.loadIfNeeded() }
        // Re-resolve logos whenever the set of projects (or their roots) changes.
        // The store skips projects whose resolved icon file is unchanged, so
        // this is cheap.
        .task(id: iconResolutionToken) {
            await iconStore.refresh(projects: model.projects)
        }
        // Probe pull requests for the unopened worktrees currently shown (under
        // expanded projects, section not collapsed, polling enabled). Re-runs
        // when that set changes, then re-polls on the policy interval to catch
        // open→merged/closed transitions; opened worktrees reuse cmux's own
        // probe and aren't fetched here.
        .task(id: worktreePullRequestProbeToken) {
            await runWorktreePullRequestProbe()
        }
        .sheet(item: $newWorktreeProject) { project in
            SupermuxNewWorktreeSheet(model: model, project: project) { worktree, workspaceName in
                openWorktree(worktree, project: project, title: workspaceName, runSetup: true)
            }
        }
        .sheet(item: $editorProject) { project in
            SupermuxProjectEditorSheet(model: model, project: project)
        }
    }

    // MARK: - Pieces
    //
    // The header, empty hint, storage notice, and add-project picker live in
    // `SupermuxProjectsSectionView+Header.swift` (Swift file-length budget).

    /// A value that changes whenever a project is added, removed, moved, or has
    /// its icon source edited, so the icon-resolution task re-runs only when an
    /// avatar could actually differ.
    private var iconResolutionToken: String {
        model.projects
            .map { "\($0.id.uuidString):\($0.rootPath):\($0.customIconPath ?? "")" }
            .joined(separator: "|")
    }

    // MARK: - Actions

    private func rowActions(for project: SupermuxProject) -> SupermuxProjectRowActions {
        SupermuxProjectRowActions(
            openLocal: { openLocal(project) },
            newWorktree: { newWorktreeProject = project },
            openWorktree: { worktree in openWorktree(worktree, project: project) },
            deleteWorktree: { worktree, deleteBranch in
                deleteWorktree(worktree, project: project, deleteBranch: deleteBranch)
            },
            toggleExpanded: {
                if model.expandedProjectIds.contains(project.id) {
                    model.expandedProjectIds.remove(project.id)
                } else {
                    model.expandedProjectIds.insert(project.id)
                    Task { await model.refreshWorktrees(for: project.id) }
                }
            },
            edit: { editorProject = project },
            remove: { model.removeProject(id: project.id) },
            revealInFinder: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.rootPath)])
            },
            launchAction: { action in launchAction(action, project: project) },
            selectWorkspace: onSelectWorkspace,
            closeWorkspace: onCloseWorkspace,
            renameWorkspace: { promptRenameWorkspace(id: $0) },
            moveUp: { moveProject(project, by: -1) },
            moveDown: { moveProject(project, by: 1) },
            reorderWorkspace: onReorderWorkspace,
            openPullRequest: onOpenPullRequest
        )
    }

    /// The projects in display order: the model's order, or the transient
    /// drag-preview order while a reorder drag is in flight (the model is
    /// reordered and persisted only once, at drag end). Nothing here reads the
    /// dragged-id markers, so a drag *start* still never invalidates this body.
    private var displayProjects: [SupermuxProject] {
        guard let preview = dragState.projectOrderPreview else { return model.projects }
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: the projects file is
        // user-editable JSON and nothing dedupes ids on load, so a hand-edited
        // duplicate must degrade to ForEach identity warnings — as it does
        // outside a drag — never to a fatalError mid-drag.
        let byId = Dictionary(model.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = preview.order.compactMap { byId[$0] }
        if ordered.count != model.projects.count {
            // Projects added mid-drag still render (appended); removed ids
            // simply drop out of the preview.
            let placed = Set(preview.order)
            ordered.append(contentsOf: model.projects.filter { !placed.contains($0.id) })
        }
        return ordered
    }

    /// Moves a project one slot up (`delta == -1`) or down (`delta == 1`) by
    /// reordering it over its immediate neighbor. Shared with drag-reorder via
    /// ``SupermuxProjectsModel/moveProject(_:over:)``.
    private func moveProject(_ project: SupermuxProject, by delta: Int) {
        guard let index = model.projects.firstIndex(where: { $0.id == project.id }) else { return }
        let neighborIndex = index + delta
        guard model.projects.indices.contains(neighborIndex) else { return }
        let neighborId = model.projects[neighborIndex].id
        withAnimation(.easeInOut(duration: 0.18)) {
            model.moveProject(project.id, over: neighborId)
        }
    }

    /// Groups open workspaces by their owning project, keyed by project id.
    ///
    /// Ownership is resolved by the host (explicit project-association or a
    /// worktree directory) and carried on ``SupermuxOpenWorkspace/projectId``;
    /// workspaces with no owner stay in cmux's flat list, so a workspace that
    /// merely inherited a project's directory is never swallowed here.
    private func workspacesByProject() -> [UUID: [SupermuxOpenWorkspace]] {
        var result: [UUID: [SupermuxOpenWorkspace]] = [:]
        for workspace in openWorkspaces {
            guard let projectId = workspace.projectId else { continue }
            result[projectId, default: []].append(workspace)
        }
        return result
    }

    private func launchAction(_ action: SupermuxProjectAction, project: SupermuxProject) {
        guard action.isLaunchable else { return }
        model.noteOpened(id: project.id)
        // Project actions run as a new tab in the focused workspace (like the
        // presets bar), not as a separate workspace — see `runAction`.
        opener.runAction(SupermuxOpenWorkspaceRequest(
            title: "\(project.name) · \(action.name)",
            directory: project.rootPath,
            colorHex: project.colorHex,
            initialCommand: action.command,
            projectId: project.id
        ))
    }

    private func openLocal(_ project: SupermuxProject) {
        model.noteOpened(id: project.id)
        opener.openWorkspace(SupermuxOpenWorkspaceRequest(
            title: project.name,
            directory: project.rootPath,
            colorHex: project.colorHex,
            projectId: project.id
        ))
    }

    /// Opens a workspace in `worktree`. When `runSetup` is true (only the
    /// just-created path), the project's setup script runs in a dedicated setup
    /// terminal of the new workspace; re-opening an existing worktree never
    /// re-runs setup.
    private func openWorktree(
        _ worktree: SupermuxProjectWorktree,
        project rawProject: SupermuxProject,
        title: String? = nil,
        runSetup: Bool = false
    ) {
        // Use the model's current record, not the (possibly stale) snapshot the
        // caller captured: `createWorktree` re-imports config.json just before
        // this runs, so the setup script must come from the refreshed project.
        let project = model.projects.first(where: { $0.id == rawProject.id }) ?? rawProject
        model.noteOpened(id: project.id)
        let resolvedTitle = title.map { $0.isEmpty ? worktree.displayName : $0 } ?? worktree.displayName
        let setupScript = runSetup ? SupermuxWorktreeScript.joined(project.setupCommands) : nil
        let setupEnvironment: [String: String] = setupScript == nil
            ? [:]
            : SupermuxWorktreeEnvironment.variables(projectRoot: project.rootPath, worktreePath: worktree.path)
        opener.openWorkspace(SupermuxOpenWorkspaceRequest(
            title: resolvedTitle,
            directory: worktree.path,
            colorHex: project.colorHex,
            projectId: project.id,
            setupScript: setupScript,
            setupEnvironment: setupEnvironment
        ))
    }

    private func deleteWorktree(_ worktree: SupermuxProjectWorktree, project: SupermuxProject, deleteBranch: Bool) {
        Task {
            do {
                try await model.removeWorktree(worktree, projectId: project.id, force: false, deleteBranch: deleteBranch)
            } catch SupermuxGitError.dirtyWorktree {
                await confirmForceDelete(worktree, project: project, deleteBranch: deleteBranch)
            } catch {
                presentError(error)
            }
        }
    }

    @MainActor
    private func confirmForceDelete(_ worktree: SupermuxProjectWorktree, project: SupermuxProject, deleteBranch: Bool) async {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.worktree.dirtyDelete.title",
            defaultValue: "Worktree has uncommitted changes"
        )
        alert.informativeText = String(
            localized: "supermux.worktree.dirtyDelete.message",
            defaultValue: "“\(worktree.displayName)” has uncommitted changes that will be lost. Delete anyway?"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "supermux.worktree.dirtyDelete.confirm", defaultValue: "Delete Anyway"))
        alert.addButton(withTitle: String(localized: "supermux.common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await model.removeWorktree(worktree, projectId: project.id, force: true, deleteBranch: deleteBranch)
        } catch {
            presentError(error)
        }
    }

    /// Prompts for a new custom title for the nested workspace `id` and hands the
    /// result to the host (which sets it via cmux's `TabManager.setCustomTitle`).
    /// Mirrors cmux's own rename dialog; an empty value clears the custom title.
    @MainActor
    private func promptRenameWorkspace(id: UUID) {
        guard let workspace = openWorkspaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "supermux.workspace.rename.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(
            localized: "supermux.workspace.rename.message",
            defaultValue: "Enter a custom name for this workspace."
        )
        let input = NSTextField(string: workspace.title)
        input.placeholderString = String(localized: "supermux.workspace.rename.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "supermux.workspace.rename.confirm", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "supermux.common.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRenameWorkspace(id, input.stringValue)
    }

    @MainActor
    private func presentError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "supermux.common.errorTitle", defaultValue: "Supermux")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

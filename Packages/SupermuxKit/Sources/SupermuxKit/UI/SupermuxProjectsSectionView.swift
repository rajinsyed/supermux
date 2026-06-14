public import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The sticky "Projects" section rendered at the top of the cmux sidebar.
///
/// Shows every registered project with quick actions to open it locally or
/// spin up a git worktree, mirroring piggycode's sticky workspaces. The host
/// app supplies a ``SupermuxWorkspaceOpening`` so activating a row opens (or
/// focuses) a real cmux workspace.
public struct SupermuxProjectsSectionView: View {
    @Bindable private var model: SupermuxProjectsModel
    private let opener: any SupermuxWorkspaceOpening
    private let openWorkspaces: [SupermuxOpenWorkspace]
    private let onSelectWorkspace: (UUID) -> Void
    private let onCloseWorkspace: (UUID) -> Void
    private let onReorderWorkspace: (UUID, UUID) -> Void
    private let onOpenPullRequest: (URL) -> Void

    /// Resolves pull requests for unopened worktrees (opened ones reuse cmux's
    /// own probe via ``SupermuxOpenWorkspace/pullRequest``). Owned here at the
    /// section level — never by a row — so rows receive immutable PR value
    /// snapshots, preserving the sidebar snapshot boundary.
    @State private var pullRequestModel = SupermuxWorktreePullRequestModel()

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
    /// Resolves and caches each project's auto-detected logo. Owned here, above
    /// the project list, so rows receive only an immutable `NSImage?` snapshot.
    @State private var iconStore = SupermuxProjectIconStore()
    /// Sidebar font scale (cmux's `sidebar-font-size`); scales the section
    /// header alongside the project rows. `1` at the default size.
    @Environment(\.supermuxSidebarFontScale) private var fontScale

    /// Creates the section.
    /// - Parameters:
    ///   - model: Shared projects model.
    ///   - opener: Host-app workspace opener.
    ///   - openWorkspaces: Snapshot of the host's live workspaces, rendered
    ///     nested under the project each belongs to. Defaults to empty.
    ///   - onSelectWorkspace: Focuses a nested workspace by id.
    ///   - onCloseWorkspace: Closes a nested workspace by id.
    ///   - onReorderWorkspace: Reorders a nested workspace `(draggedId,
    ///     targetId)` within its project (wired to the host's tab order).
    ///   - onOpenPullRequest: Opens a PR badge's URL. Defaults to the system
    ///     browser; the host overrides it to honor cmux's PR-link routing.
    public init(
        model: SupermuxProjectsModel,
        opener: any SupermuxWorkspaceOpening,
        openWorkspaces: [SupermuxOpenWorkspace] = [],
        onSelectWorkspace: @escaping (UUID) -> Void = { _ in },
        onCloseWorkspace: @escaping (UUID) -> Void = { _ in },
        onReorderWorkspace: @escaping (UUID, UUID) -> Void = { _, _ in },
        onOpenPullRequest: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.model = model
        self.opener = opener
        self.openWorkspaces = openWorkspaces
        self.onSelectWorkspace = onSelectWorkspace
        self.onCloseWorkspace = onCloseWorkspace
        self.onReorderWorkspace = onReorderWorkspace
        self.onOpenPullRequest = onOpenPullRequest
    }

    public var body: some View {
        let grouped = workspacesByProject()
        VStack(alignment: .leading, spacing: 2) {
            header
            if !model.isSectionCollapsed {
                ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                    SupermuxProjectRowView(
                        project: project,
                        detectedIcon: iconStore.image(for: project.id),
                        worktrees: model.worktreesByProjectId[project.id] ?? [],
                        worktreePullRequests: worktreePullRequests(for: project.id),
                        openWorkspaces: grouped[project.id] ?? [],
                        isExpanded: model.expandedProjectIds.contains(project.id),
                        actions: rowActions(for: project),
                        canMoveUp: index > 0,
                        canMoveDown: index < model.projects.count - 1,
                        beginDrag: {
                            dragState.draggingProjectId = project.id
                            return NSItemProvider(object: project.id.uuidString as NSString)
                        },
                        dropDelegate: SupermuxProjectDropDelegate(
                            targetProjectId: project.id,
                            draggingProjectId: $dragState.draggingProjectId,
                            move: { dragged, target in
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    model.moveProject(dragged, over: target)
                                }
                            }
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
        // A drag released off any row (an abort) never reaches a `performDrop`,
        // so without this the source row would stay dimmed. The failsafe clears
        // the marker on the next mouse-up / Escape; the deferred clear lets a
        // real drop's `performDrop` run (and reorder) first.
        .onAppear { dragFailsafe.start(clearing: dragState) }
        .onDisappear { dragFailsafe.stop() }
        .task { await model.loadIfNeeded() }
        // Re-resolve logos whenever the set of projects (or their roots) changes.
        // The store skips projects whose root is unchanged, so this is cheap.
        .task(id: iconResolutionToken) {
            await iconStore.refresh(projects: model.projects)
        }
        // Probe pull requests for the unopened worktrees currently shown (under
        // expanded projects). Re-runs when that set changes, then re-polls on a
        // slow interval to catch open→merged/closed transitions; opened worktrees
        // reuse cmux's own probe and aren't fetched here.
        .task(id: worktreePullRequestProbeToken) {
            let targets = worktreePullRequestTargets
            guard !targets.isEmpty else {
                await pullRequestModel.refresh(targets: [], allowCache: false)
                return
            }
            var allowCache = false
            while !Task.isCancelled {
                await pullRequestModel.refresh(targets: targets, allowCache: allowCache)
                allowCache = true
                try? await Task.sleep(for: .seconds(60))
            }
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

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.isSectionCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.isSectionCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8 * fontScale, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "supermux.projects.header", defaultValue: "Projects"))
                        .font(.system(size: 10.5 * fontScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                pickAndAddProject()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10 * fontScale, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "supermux.projects.add.help", defaultValue: "Add a project folder"))
            .accessibilityLabel(String(localized: "supermux.projects.add.help", defaultValue: "Add a project folder"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private var emptyHint: some View {
        Text(String(
            localized: "supermux.projects.empty",
            defaultValue: "Add a repo to pin it here"
        ))
        .font(.system(size: 10.5 * fontScale))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// A value that changes whenever a project is added, removed, or moved, so
    /// the icon-resolution task re-runs only when logo locations could differ.
    private var iconResolutionToken: String {
        model.projects.map { "\($0.id.uuidString):\($0.rootPath)" }.joined(separator: "|")
    }

    /// The unopened worktrees (under expanded projects) to probe for pull
    /// requests. Opened worktrees nest as workspace rows and reuse cmux's own
    /// probe, so they are excluded here.
    private var worktreePullRequestTargets: [SupermuxPullRequestTarget] {
        let openDirectories = Set(openWorkspaces.map {
            ($0.directory as NSString).standardizingPath
        })
        var targets: [SupermuxPullRequestTarget] = []
        for project in model.projects where model.expandedProjectIds.contains(project.id) {
            for worktree in model.worktreesByProjectId[project.id] ?? [] {
                guard let branch = worktree.branch else { continue }
                if openDirectories.contains((worktree.path as NSString).standardizingPath) { continue }
                targets.append(SupermuxPullRequestTarget(path: worktree.path, branch: branch))
            }
        }
        return targets
    }

    /// A value that changes whenever the set of unopened worktrees to probe
    /// changes (expand/collapse, worktree created/deleted, opened/closed), so the
    /// probe task restarts with the current targets.
    private var worktreePullRequestProbeToken: String {
        worktreePullRequestTargets
            .map { "\($0.path)\u{1}\($0.branch)" }
            .sorted()
            .joined(separator: "\u{2}")
    }

    /// This project's resolved unopened-worktree pull requests, keyed by worktree
    /// path — the immutable value snapshot handed to its row.
    private func worktreePullRequests(for projectId: UUID) -> [String: SupermuxPullRequest] {
        let resolved = pullRequestModel.pullRequestsByWorktreePath
        guard !resolved.isEmpty, let worktrees = model.worktreesByProjectId[projectId] else { return [:] }
        var result: [String: SupermuxPullRequest] = [:]
        for worktree in worktrees where resolved[worktree.path] != nil {
            result[worktree.path] = resolved[worktree.path]
        }
        return result
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
            moveUp: { moveProject(project, by: -1) },
            moveDown: { moveProject(project, by: 1) },
            reorderWorkspace: onReorderWorkspace,
            openPullRequest: onOpenPullRequest
        )
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

    private func pickAndAddProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "supermux.projects.add.prompt", defaultValue: "Add Project")
        panel.message = String(
            localized: "supermux.projects.add.message",
            defaultValue: "Choose a repository or folder to pin as a project"
        )
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task {
            for path in paths {
                await model.addProject(rootPath: path)
            }
        }
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

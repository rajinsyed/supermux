public import SwiftUI
import AppKit

/// The sticky "Projects" section rendered at the top of the cmux sidebar.
///
/// Shows every registered project with quick actions to open it locally or
/// spin up a git worktree, mirroring piggycode's sticky workspaces. The host
/// app supplies a ``SupermuxWorkspaceOpening`` so activating a row opens (or
/// focuses) a real cmux workspace.
public struct SupermuxProjectsSectionView: View {
    @Bindable private var model: SupermuxProjectsModel
    private let opener: any SupermuxWorkspaceOpening

    @State private var newWorktreeProject: SupermuxProject?
    @State private var editorProject: SupermuxProject?

    /// Creates the section.
    /// - Parameters:
    ///   - model: Shared projects model.
    ///   - opener: Host-app workspace opener.
    public init(model: SupermuxProjectsModel, opener: any SupermuxWorkspaceOpening) {
        self.model = model
        self.opener = opener
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !model.isSectionCollapsed {
                ForEach(model.projects) { project in
                    SupermuxProjectRowView(
                        project: project,
                        worktrees: model.worktreesByProjectId[project.id] ?? [],
                        isExpanded: model.expandedProjectIds.contains(project.id),
                        actions: rowActions(for: project)
                    )
                }
                if model.projects.isEmpty {
                    emptyHint
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .task { await model.loadIfNeeded() }
        .sheet(item: $newWorktreeProject) { project in
            SupermuxNewWorktreeSheet(model: model, project: project) { worktree in
                openWorktree(worktree, project: project)
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
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "supermux.projects.header", defaultValue: "Projects"))
                        .font(.system(size: 10.5, weight: .semibold))
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
                    .font(.system(size: 10, weight: .semibold))
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
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
            launchAction: { action in launchAction(action, project: project) }
        )
    }

    private func launchAction(_ action: SupermuxProjectAction, project: SupermuxProject) {
        guard action.isLaunchable else { return }
        model.noteOpened(id: project.id)
        opener.openWorkspace(SupermuxOpenWorkspaceRequest(
            title: "\(project.name) · \(action.name)",
            directory: project.rootPath,
            colorHex: project.colorHex,
            initialCommand: action.command
        ))
    }

    private func openLocal(_ project: SupermuxProject) {
        model.noteOpened(id: project.id)
        opener.openWorkspace(SupermuxOpenWorkspaceRequest(
            title: project.name,
            directory: project.rootPath,
            colorHex: project.colorHex
        ))
    }

    private func openWorktree(_ worktree: SupermuxProjectWorktree, project: SupermuxProject) {
        model.noteOpened(id: project.id)
        opener.openWorkspace(SupermuxOpenWorkspaceRequest(
            title: worktree.displayName,
            directory: worktree.path,
            colorHex: project.colorHex
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

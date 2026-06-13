import AppKit
import CmuxProcess
import SupermuxKit
import SwiftUI

/// Composition point for supermux features inside the cmux app target.
///
/// Supermux deliberately deviates from the repo's no-static-state rule here:
/// constructing the runtime at the AppDelegate composition root would require
/// touching heavily-churned upstream files, and minimizing the upstream merge
/// surface is supermux's prime directive (see SUPERMUX.md). This enum is the
/// single sanctioned global for supermux state; everything behind it uses
/// constructor injection.
@MainActor
enum SupermuxComposition {
    /// App-wide projects model, shared by every window's sidebar.
    static let projectsModel: SupermuxProjectsModel = {
        let store = SupermuxProjectStore(fileURL: SupermuxPaths.defaultProjectsFileURL)
        let service = SupermuxGitWorktreeService(runner: CommandRunner())
        return SupermuxProjectsModel(store: store, worktreeService: service)
    }()

    /// App-wide run-action coordinator behind the ⌘G shortcut.
    static let runCoordinator = SupermuxRunCoordinator(projectsModel: projectsModel)
}

/// Filters which workspaces cmux's flat sidebar list should render.
///
/// Workspaces that belong to a registered project are shown nested under that
/// project in the Projects section (piggycode-style), so they are hidden from
/// the flat list to avoid duplication. This is purely a display filter —
/// `TabManager.tabs` is untouched, so selection, ⌘-number navigation, and
/// workspace lifecycle still operate on the full set. Workspaces that already
/// belong to a cmux workspace group, or any workspace when no projects are
/// registered, are never filtered.
@MainActor
enum SupermuxMainListFilter {
    private static let matcher = SupermuxProjectMatcher()

    /// Returns the workspaces to render in cmux's flat list, with
    /// project-owned (ungrouped) workspaces removed.
    /// - Parameter tabs: All workspaces from `TabManager.tabs`.
    static func tabsForMainList(_ tabs: [Workspace]) -> [Workspace] {
        let projects = SupermuxComposition.projectsModel.projects
        guard !projects.isEmpty else { return tabs }
        return tabs.filter { workspace in
            // Leave cmux-grouped workspaces alone; only hide loose workspaces
            // that a project owns.
            if workspace.groupId != nil { return true }
            return matcher.project(for: workspace.currentDirectory, in: projects) == nil
        }
    }
}

/// Opens supermux workspace requests through a window's `TabManager`:
/// focuses an existing workspace whose directory already matches, otherwise
/// creates a new one at the requested directory.
@MainActor
final class SupermuxTabManagerOpener: SupermuxWorkspaceOpening {
    private weak var tabManager: TabManager?

    /// Creates an opener bound to one window's tab manager.
    /// - Parameter tabManager: The window's workspace manager.
    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func openWorkspace(_ request: SupermuxOpenWorkspaceRequest) {
        guard let tabManager else { return }
        let directory = (request.directory as NSString).expandingTildeInPath
        // A command-carrying request always opens a fresh workspace so the
        // command runs in a clean terminal; plain "open" requests reuse a
        // matching workspace when one already exists.
        if request.initialCommand == nil,
           let existing = tabManager.tabs.first(where: { workspace in
               (workspace.currentDirectory as NSString).expandingTildeInPath == directory
           }) {
            tabManager.selectWorkspace(existing)
            return
        }
        let workspace = tabManager.addWorkspace(
            title: request.title,
            workingDirectory: directory,
            initialTerminalCommand: request.initialCommand,
            inheritWorkingDirectory: false,
            select: true
        )
        workspace.customTitle = request.title
        if let colorHex = request.colorHex {
            workspace.customColor = colorHex
        }
    }
}

/// The view mounted inside the cmux sidebar (see the `sidebar-projects-section`
/// touchpoint in `ContentView.swift`). Bridges the window's environment to the
/// package-owned projects section.
struct SupermuxProjectsMount: View {
    @EnvironmentObject private var tabManager: TabManager

    var body: some View {
        // Reading tabs/selectedTabId here subscribes this small, eager section
        // to workspace add/remove/select changes (not per-keystroke output), so
        // a project's live workspaces stay nested and in sync underneath it.
        let openWorkspaces = tabManager.tabs.map { workspace in
            SupermuxOpenWorkspace(
                id: workspace.id,
                title: workspace.customTitle ?? workspace.title,
                directory: workspace.currentDirectory,
                isSelected: workspace.id == tabManager.selectedTabId,
                branch: workspace.gitBranch?.branch
            )
        }
        SupermuxProjectsSectionView(
            model: SupermuxComposition.projectsModel,
            opener: SupermuxTabManagerOpener(tabManager: tabManager),
            openWorkspaces: openWorkspaces,
            onSelectWorkspace: { [weak tabManager] id in
                guard let workspace = tabManager?.tabs.first(where: { $0.id == id }) else { return }
                tabManager?.selectWorkspace(workspace)
            },
            onCloseWorkspace: { [weak tabManager] id in
                guard let workspace = tabManager?.tabs.first(where: { $0.id == id }) else { return }
                _ = tabManager?.closeWorkspaceWithConfirmation(workspace)
            }
        )
    }
}

/// The git Changes panel mounted as the right sidebar's `changes` mode (see
/// the `right-sidebar-changes-mode-*` touchpoints). Each mount owns its model
/// so separate windows track their own active workspace independently.
struct SupermuxChangesMount: View {
    let workspaceDirectory: String?

    @EnvironmentObject private var tabManager: TabManager
    @State private var model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: CommandRunner()))

    var body: some View {
        SupermuxChangesPanelView(
            model: model,
            onOpenDiff: { [weak tabManager] in
                guard let tabManager,
                      let appDelegate = NSApp.delegate as? AppDelegate else { return }
                _ = appDelegate.openDiffViewerForFocusedWorkspace(for: tabManager)
            }
        )
        .onAppear { model.setDirectory(workspaceDirectory) }
        .onChange(of: workspaceDirectory) { _, newDirectory in
            model.setDirectory(newDirectory)
        }
    }
}

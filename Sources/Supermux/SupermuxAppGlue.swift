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
        if let existing = tabManager.tabs.first(where: { workspace in
            (workspace.currentDirectory as NSString).expandingTildeInPath == directory
        }) {
            tabManager.selectWorkspace(existing)
            return
        }
        let workspace = tabManager.addWorkspace(
            title: request.title,
            workingDirectory: directory,
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
        SupermuxProjectsSectionView(
            model: SupermuxComposition.projectsModel,
            opener: SupermuxTabManagerOpener(tabManager: tabManager)
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

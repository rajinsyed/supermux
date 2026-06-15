import AppKit
import Combine
import CmuxProcess
import CmuxSettings
import CmuxSocketControl
import Foundation
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
    /// App-wide AI gateway client. Reads the Vercel AI Gateway key from the same
    /// secure `0600` file the Settings card writes (under the cmux state
    /// directory), so a key pasted in Settings is picked up without rebuilding
    /// the client.
    static let aiClient: any SupermuxAICompleting = {
        let store = SecretFileStore(
            baseDirectory: CmuxStateDirectory.url(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        )
        let key = SecretFileKey(id: SupermuxAIConfig.secretKeyID, fileName: SupermuxAIConfig.secretFileName)
        return SupermuxAIGatewayClient(apiKeyProvider: {
            guard let value = try? await store.value(for: key), !value.isEmpty else { return nil }
            return value
        })
    }()

    /// AI branch-name suggester for the new-worktree flow.
    static let aiBranchNamer: any SupermuxAIBranchNaming = SupermuxAIBranchNamer(client: aiClient)

    /// AI commit-message generator for the Changes panel.
    static let aiCommitMessenger: any SupermuxAICommitMessaging = SupermuxAICommitMessenger(client: aiClient)

    /// App-wide projects model, shared by every window's sidebar.
    static let projectsModel: SupermuxProjectsModel = {
        let store = SupermuxProjectStore(fileURL: SupermuxPaths.defaultProjectsFileURL)
        let service = SupermuxGitWorktreeService(runner: CommandRunner())
        return SupermuxProjectsModel(store: store, worktreeService: service, branchNamer: aiBranchNamer)
    }()

    /// App-wide run-action coordinator behind the ⌘G shortcut.
    static let runCoordinator = SupermuxRunCoordinator(projectsModel: projectsModel)

    /// Tracks which workspaces were explicitly opened from a project, so only
    /// those (plus worktrees, matched by directory) nest under a project —
    /// workspaces created via cmux's normal flow stay standalone even when
    /// their directory happens to sit inside a registered project. Backed by the
    /// projects model so the link survives a restart by directory (a project's
    /// main workspace sits at the root and has no worktree-dir signal).
    static let workspaceAssociations = SupermuxWorkspaceAssociationStore(persistence: projectsModel)
}

/// Filters which workspaces cmux's flat sidebar list should render.
///
/// Workspaces that belong to a registered project are shown nested under that
/// project in the Projects section (piggycode-style), so they are hidden from
/// the flat list to avoid duplication. A workspace belongs to a project only
/// when it was explicitly opened from it (``SupermuxWorkspaceAssociationStore``)
/// or physically lives in the project's worktrees dir — never merely because
/// its directory sits inside a project root. This is what lets the user create
/// standalone workspaces (cmux's ⌘T/+) without them being swallowed by a
/// project whose directory they happened to inherit.
///
/// This is purely a display filter — `TabManager.tabs` is untouched, so
/// selection, ⌘-number navigation, and workspace lifecycle still operate on the
/// full set. Workspaces that already belong to a cmux workspace group, or any
/// workspace when no projects are registered, are never filtered.
@MainActor
enum SupermuxMainListFilter {
    /// Returns the workspaces to render in cmux's flat list, with
    /// project-owned (ungrouped) workspaces removed.
    /// - Parameter tabs: All workspaces from `TabManager.tabs`.
    static func tabsForMainList(_ tabs: [Workspace]) -> [Workspace] {
        let projects = SupermuxComposition.projectsModel.projects
        guard !projects.isEmpty else { return tabs }
        let associations = SupermuxComposition.workspaceAssociations
        return tabs.filter { workspace in
            // Leave cmux-grouped workspaces alone; only hide loose workspaces
            // that a project owns (explicit association or a worktree dir).
            if workspace.groupId != nil { return true }
            return associations.projectId(
                forWorkspace: workspace.id,
                directory: workspace.currentDirectory,
                in: projects
            ) == nil
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
        // A command- or setup-carrying request always opens a fresh workspace so
        // the work runs in a clean terminal; plain "open" requests reuse a
        // matching workspace when one already exists.
        if request.initialCommand == nil,
           request.setupScript == nil,
           let existing = tabManager.tabs.first(where: { workspace in
               (workspace.currentDirectory as NSString).expandingTildeInPath == directory
           }) {
            tabManager.selectWorkspace(existing)
            associate(workspaceId: existing.id, directory: directory, with: request)
            return
        }
        // Run the action's command through the new workspace's interactive
        // shell (see SupermuxCommandLaunch): resolves shell aliases/functions
        // (e.g. `cc` → `claude …`) and keeps the workspace open after the
        // command exits instead of collapsing it. Plain "open" requests carry
        // no command and just get a clean terminal.
        let workspace = tabManager.addWorkspace(
            title: request.title,
            workingDirectory: directory,
            initialTerminalInput: request.initialCommand.map(SupermuxCommandLaunch.shellInput),
            inheritWorkingDirectory: false,
            select: true
        )
        workspace.customTitle = request.title
        if let colorHex = request.colorHex {
            workspace.customColor = colorHex
        }
        associate(workspaceId: workspace.id, directory: directory, with: request)
        runSetupScriptIfNeeded(in: workspace, directory: directory, request: request)
    }

    /// Spawns a dedicated, focused setup terminal in `workspace` that runs the
    /// request's setup script with its environment exported, leaving the
    /// workspace's clean main terminal untouched. Used right after a worktree is
    /// created. No-op when the request carries no setup script.
    private func runSetupScriptIfNeeded(in workspace: Workspace, directory: String, request: SupermuxOpenWorkspaceRequest) {
        guard let setupScript = request.setupScript,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else { return }
        // Run as interactive-shell input (see SupermuxCommandLaunch) so aliases
        // resolve and the surface survives the command's exit; the worktree
        // environment is delivered through the PTY's startup environment so the
        // script (e.g. `cp "$SUPERSET_ROOT_PATH/.env" .env`) sees it directly.
        _ = workspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: directory,
            initialInput: SupermuxCommandLaunch.shellInput(for: setupScript),
            startupEnvironment: request.setupEnvironment
        )
    }

    /// Runs a project action's command as a new terminal tab in the focused
    /// workspace (the ⌘-presets-bar behavior), not as a separate workspace.
    ///
    /// The command runs through the workspace's interactive shell (see
    /// ``SupermuxCommandLaunch``) so shell aliases/functions resolve and the tab
    /// survives the command exit. The action's project directory is used as the
    /// tab's working directory so a build/run command still runs in the right
    /// place. With no focused workspace to host the tab, falls back to opening a
    /// fresh workspace.
    func runAction(_ request: SupermuxOpenWorkspaceRequest) {
        guard let tabManager,
              let command = request.initialCommand,
              let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            openWorkspace(request)
            return
        }
        let directory = (request.directory as NSString).expandingTildeInPath
        _ = workspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: directory,
            initialInput: SupermuxCommandLaunch.shellInput(for: command)
        )
    }

    /// Records the workspace→project association for project-originated opens,
    /// so the resulting workspace nests under that project in the sidebar — and
    /// re-nests after a restart, since the link is persisted by `directory`.
    private func associate(workspaceId: UUID, directory: String, with request: SupermuxOpenWorkspaceRequest) {
        guard let projectId = request.projectId else { return }
        SupermuxComposition.workspaceAssociations.associate(
            workspaceId: workspaceId,
            projectId: projectId,
            directory: directory
        )
    }
}

/// The view mounted inside the cmux sidebar (see the `sidebar-projects-section`
/// touchpoint in `ContentView.swift`). Bridges the window's environment to the
/// package-owned projects section.
struct SupermuxProjectsMount: View {
    @EnvironmentObject private var tabManager: TabManager

    /// Live sidebar font scale (cmux's `sidebar-font-size`), injected into the
    /// Projects section so project rows and nested workspaces grow/shrink with
    /// the same setting as the flat workspace list.
    @StateObject private var fontScaleStore = SupermuxSidebarFontScaleStore()

    /// Owns the per-workspace observation subscription (git branch, working
    /// directory, status, in-place title renames) so a late field change
    /// re-reads the nested snapshots. Its lifetime is kept out of `body` to avoid
    /// a render→resubscribe→replay→invalidate spin — see
    /// ``SupermuxWorkspaceObservation``.
    @StateObject private var observation = SupermuxWorkspaceObservation()

    var body: some View {
        // Make the body's dependency on the observation token explicit (cmux
        // does the same with `extensionSidebarUpdateToken`): a token bump forces
        // the per-workspace snapshots below to be rebuilt from current state.
        let _ = observation.token
        // Reading tabs/selectedTabId here subscribes this small, eager section
        // to workspace add/remove/select changes (not per-keystroke output), so
        // a project's live workspaces stay nested and in sync underneath it.
        let projects = SupermuxComposition.projectsModel.projects
        let associations = SupermuxComposition.workspaceAssociations
        let openWorkspaces = tabManager.tabs.map { workspace in
            SupermuxWorkspaceRow.snapshot(
                for: workspace,
                isSelected: workspace.id == tabManager.selectedTabId,
                projectId: associations.projectId(
                    forWorkspace: workspace.id,
                    directory: workspace.currentDirectory,
                    in: projects
                ),
                isRunning: SupermuxComposition.runCoordinator.isRunning(workspaceId: workspace.id)
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
                // Drop only the session link; the durable directory link is a
                // project-level fact that survives until the project is removed,
                // so a cancelled close or a sibling at the same directory still
                // nests.
                SupermuxComposition.workspaceAssociations.forget(workspaceId: id)
                guard let workspace = tabManager?.tabs.first(where: { $0.id == id }) else { return }
                _ = tabManager?.closeWorkspaceWithConfirmation(workspace)
            },
            onRenameWorkspace: { [weak tabManager] id, title in
                // Route through cmux's shared rename mutation: an empty/whitespace
                // title clears the custom title and reverts to the process title.
                tabManager?.setCustomTitle(tabId: id, title: title)
            },
            onReorderWorkspace: { [weak tabManager] draggedId, targetId in
                // Reorder the dragged workspace adjacent to the target in cmux's
                // own tab order (the source of the nested list). Direction is
                // taken from their current positions so dropping lands the row
                // just below the target when dragging down, above when up.
                guard let tabManager,
                      let from = tabManager.tabs.firstIndex(where: { $0.id == draggedId }),
                      let to = tabManager.tabs.firstIndex(where: { $0.id == targetId }),
                      from != to else { return }
                if from < to {
                    _ = tabManager.reorderWorkspace(tabId: draggedId, after: targetId, isDragOperation: true)
                } else {
                    _ = tabManager.reorderWorkspace(tabId: draggedId, before: targetId, isDragOperation: true)
                }
            },
            onOpenPullRequest: { [weak tabManager] url in
                // Honor cmux's PR-link routing: open in the cmux browser when the
                // setting is on and a workspace is active, else the default browser.
                if BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(),
                   let tabManager,
                   let tabId = tabManager.selectedTabId,
                   tabManager.openBrowser(
                       inWorkspace: tabId,
                       url: url,
                       preferSplitRight: true,
                       insertAtEnd: true
                   ) != nil {
                    return
                }
                _ = NSWorkspace.shared.open(url)
            }
        )
        // Subscribe once on appear and re-subscribe only when the set of open
        // workspaces changes — never per render (see `observation`'s note).
        .onAppear { observation.observe(tabs: tabManager.tabs) }
        .onChange(of: tabManager.tabs.map(\.id)) {
            observation.observe(tabs: tabManager.tabs)
        }
        .environment(\.supermuxSidebarFontScale, fontScaleStore.fontScale)
        // Publish this section's height so the sidebar shrinks the empty area
        // below the rows by it (else the content overflows and the empty space
        // scrolls — see SupermuxProjectsSectionHeightPreferenceKey + cmux #3241).
        .supermuxReportsProjectsSectionHeight()
    }
}

/// Owns the merged Combine subscription that drives ``SupermuxProjectsMount``'s
/// per-workspace re-reads, keeping the subscription's lifetime out of `body`.
///
/// Each workspace contributes its `$title` publisher — so renaming a nested
/// workspace via `setCustomTitle` (which mutates `title` in place on the
/// `Workspace`, firing no `TabManager` `@Published`) re-titles its row at once,
/// matching cmux's own sidebar — plus its `sidebarObservationPublisher`
/// (`gitBranch`, `currentDirectory`, status — the late-detected branch update).
/// We observe `$title` alone rather than the full
/// `sidebarImmediateObservationPublisher` so this eager section is not rebuilt by
/// the conversation/activity fields that publisher also carries.
///
/// Rebuilding this merge inside `body` and feeding it to `.onReceive` resubscribed
/// every render, and on each new subscription the `@Published` inputs behind
/// `sidebarObservationPublisher` re-send their current values (the `CombineLatest`
/// then emits) — which drove a render→resubscribe→replay→invalidate feedback loop
/// that pegged a CPU core. By owning the subscription here and rebuilding it only
/// when the set of open workspaces changes, steady-state renders never resubscribe,
/// so `removeDuplicates()` suppresses everything but real field changes.
@MainActor
final class SupermuxWorkspaceObservation: ObservableObject {
    /// Bumped on each observed per-workspace field change; read by the mount's
    /// `body` to re-read the nested workspace snapshots.
    @Published private(set) var token = 0

    private var observedIds: Set<UUID> = []
    private var cancellable: AnyCancellable?

    /// (Re)subscribes to the workspaces' sidebar-observation streams, but only
    /// when the set of open workspaces actually changes — so steady-state renders
    /// (and pure reorders, which keep the same set) never rebuild the
    /// subscription. `.receive(on:)` defers delivery past `@Published`'s `willSet`
    /// so the next body re-read sees the committed value.
    func observe(tabs: [Workspace]) {
        let ids = Set(tabs.map(\.id))
        guard ids != observedIds else { return }
        observedIds = ids

        let publishers: [AnyPublisher<Void, Never>] = tabs.flatMap { workspace in
            [
                workspace.$title.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                workspace.sidebarObservationPublisher,
            ]
        }
        guard !publishers.isEmpty else {
            cancellable = nil
            return
        }
        cancellable = Publishers.MergeMany(publishers)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.token &+= 1 }
    }
}

/// The git Changes panel mounted as the right sidebar's `changes` mode (see
/// the `right-sidebar-changes-mode-*` touchpoints). Each mount owns its model
/// so separate windows track their own active workspace independently.
struct SupermuxChangesMount: View {
    let workspaceDirectory: String?

    @EnvironmentObject private var tabManager: TabManager
    @State private var model = SupermuxChangesModel(
        service: SupermuxGitChangesService(runner: CommandRunner()),
        commitGenerator: SupermuxComposition.aiCommitMessenger
    )

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

/// The terminal presets bar mounted above each workspace's terminal area (see
/// the `presets-bar` touchpoint in `WorkspaceContentView.swift`). Bridges the
/// workspace to the package-owned ``SupermuxPresetsBarView``: clicking a preset
/// opens its command in a fresh terminal tab in the focused pane, and the Run
/// button toggles this workspace's project run command (the ⌘G action).
struct SupermuxPresetsBarMount: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var shortcutObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        // Subscribes the bar to live run-state changes (Run ↔ Stop) and shortcut
        // rebinds; preset edits invalidate inside the bar view, not here.
        let _ = shortcutObserver.revision
        let runCoordinator = SupermuxComposition.runCoordinator
        SupermuxPresetsBarView(
            model: SupermuxComposition.projectsModel,
            isRunning: runCoordinator.isRunning(workspaceId: workspace.id),
            runShortcutHint: KeyboardShortcutSettings.shortcut(for: .supermuxToggleRun).displayString,
            onLaunch: { [weak workspace] preset in
                guard let workspace, preset.isLaunchable else { return }
                guard let paneId = workspace.bonsplitController.focusedPaneId
                    ?? workspace.bonsplitController.allPaneIds.first else { return }
                // Run the preset through the interactive shell (see
                // SupermuxCommandLaunch): resolves shell aliases/functions and
                // keeps the tab open after the command exits.
                _ = workspace.newTerminalSurface(
                    inPane: paneId,
                    focus: true,
                    workingDirectory: workspace.currentDirectory,
                    initialInput: SupermuxCommandLaunch.shellInput(for: preset.command)
                )
            },
            onToggleRun: { [weak workspace] in
                guard let workspace else { return }
                _ = SupermuxComposition.runCoordinator.toggleRun(workspace: workspace)
            }
        )
    }
}

/// Builds the immutable ``SupermuxOpenWorkspace`` snapshot that a project-nested
/// sidebar row renders from a live ``Workspace``.
///
/// Extracted from ``SupermuxProjectsMount`` so the row's field mapping — most
/// importantly which source feeds the branch subtitle — is unit-testable
/// without a SwiftUI host. `projectId`/`isRunning` are passed in because they
/// depend on app-wide composition the caller already holds.
@MainActor
enum SupermuxWorkspaceRow {
    static func snapshot(
        for workspace: Workspace,
        isSelected: Bool,
        projectId: UUID?,
        isRunning: Bool
    ) -> SupermuxOpenWorkspace {
        // Reuse cmux's own per-workspace PR probe for opened worktrees: the first
        // display-ordered PR is the representative one (cmux prioritizes
        // open > merged > closed and freshness). No supermux probe runs here.
        let pullRequest = workspace.sidebarPullRequestsInDisplayOrder().first
            .flatMap(SupermuxPullRequest.init(sidebarState:))
        return SupermuxOpenWorkspace(
            id: workspace.id,
            title: workspace.customTitle ?? workspace.title,
            directory: workspace.currentDirectory,
            isSelected: isSelected,
            branch: workspace.supermuxSidebarBranch,
            projectId: projectId,
            activity: SupermuxWorkspaceActivityResolver.activity(for: workspace),
            isRunning: isRunning,
            pullRequest: pullRequest
        )
    }
}

extension SupermuxPullRequest {
    /// Bridges cmux's per-workspace ``SidebarPullRequestState`` into the supermux
    /// badge value, so opened worktrees reuse cmux's own PR probe. Returns `nil`
    /// only if the status string is unrecognized.
    init?(sidebarState state: SidebarPullRequestState) {
        guard let status = Status(rawValue: state.status.rawValue) else { return nil }
        self.init(number: state.number, status: status, url: state.url, isStale: state.isStale)
    }
}

extension Workspace {
    /// The git branch shown on a supermux project-nested workspace row.
    ///
    /// Resolves from the per-panel, display-ordered branches
    /// (``sidebarGitBranchesInDisplayOrder()``) — the same source cmux's own
    /// sidebar rows use — rather than the workspace-level `gitBranch` mirror.
    /// `gitBranch` only ever reflects the *focused* panel's branch, so focusing
    /// a branchless surface (e.g. opening a browser tab) clears it and the row's
    /// branch subtitle would vanish even though a terminal in the workspace is
    /// still on a branch. The per-panel branches persist across focus changes,
    /// so this stays stable; it falls back to `gitBranch` only when no panel
    /// reports a branch.
    var supermuxSidebarBranch: String? {
        sidebarGitBranchesInDisplayOrder().first?.branch
    }
}

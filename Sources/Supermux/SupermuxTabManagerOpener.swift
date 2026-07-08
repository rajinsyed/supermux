import CmuxSidebar
import Foundation
import SupermuxKit
import os

/// Opens supermux workspace requests through a window's `TabManager`:
/// focuses an existing workspace whose directory already matches, otherwise
/// creates a new one at the requested directory.
@MainActor
final class SupermuxTabManagerOpener: SupermuxWorkspaceOpening {
    private weak var tabManager: TabManager?
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "supermux.opener")

    /// Creates an opener bound to one window's tab manager.
    /// - Parameter tabManager: The window's workspace manager.
    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func openWorkspace(_ request: SupermuxOpenWorkspaceRequest) {
        openWorkspaceReturningWorkspaceId(request)
    }

    /// The one shared open path behind ``openWorkspace(_:)``, additionally
    /// reporting which workspace served the request (focused or created) so
    /// RPC callers (`mobile.supermux.project.open` / `worktree.open` /
    /// `worktree.create {open: true}`) can return a `workspace_id`. Returns
    /// `nil` only when the window's tab manager is gone.
    @discardableResult
    func openWorkspaceReturningWorkspaceId(_ request: SupermuxOpenWorkspaceRequest) -> UUID? {
        guard let tabManager else { return nil }
        let directory = (request.directory as NSString).expandingTildeInPath
        // A command- or setup-carrying request always opens a fresh workspace so
        // the work runs in a clean terminal; plain "open" requests reuse a
        // matching workspace when one already exists. The REQUEST directory is
        // matched in both its normalized and symlink-resolved forms (so /tmp/x
        // vs /private/tmp/x and symlinked project roots still unify), but each
        // workspace's `currentDirectory` is only normalized, never resolved:
        // it can be a remote-mirror path (e.g. /home/… on a remote tmux
        // workspace) where `resolvingSymlinksInPath`'s per-component stat
        // calls block the main actor on the autofs automounter — the rule
        // ``SupermuxProjectMatcher``'s header mandates for interaction paths.
        // Physical-request vs logical-cwd duplicates therefore remain
        // possible; deduping via the (request-side, safely resolvable)
        // associated directories would need a directory-by-workspace accessor
        // on the association store, which it does not expose today.
        let targets = Set([
            SupermuxProjectMatcher.normalizedDirectory(directory),
            SupermuxProjectMatcher.resolvedDirectory(directory),
        ])
        if request.initialCommand == nil,
           request.setupScript == nil,
           let existing = tabManager.tabs.first(where: { workspace in
               targets.contains(SupermuxProjectMatcher.normalizedDirectory(workspace.currentDirectory))
           }) {
            tabManager.selectWorkspace(existing)
            associate(workspaceId: existing.id, directory: directory, with: request)
            return existing.id
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
        // Route through cmux's shared rename mutation (trims whitespace; an
        // empty title clears back to the process title) instead of assigning
        // `customTitle` directly.
        tabManager.setCustomTitle(tabId: workspace.id, title: request.title)
        if let colorHex = request.colorHex {
            workspace.customColor = colorHex
        }
        associate(workspaceId: workspace.id, directory: directory, with: request)
        runSetupScriptIfNeeded(in: workspace, directory: directory, request: request)
        return workspace.id
    }

    /// Spawns a dedicated, focused setup terminal in `workspace` that runs the
    /// request's setup script with its environment exported, leaving the
    /// workspace's clean main terminal untouched. Used right after a worktree is
    /// created. No-op when the request carries no setup script.
    private func runSetupScriptIfNeeded(in workspace: Workspace, directory: String, request: SupermuxOpenWorkspaceRequest) {
        guard let setupScript = request.setupScript else { return }
        guard let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            Self.logger.warning("setup script dropped: no pane in workspace \(workspace.id, privacy: .public)")
            return
        }
        // Run as interactive-shell input (see SupermuxCommandLaunch) so aliases
        // resolve and the surface survives the command's exit; the worktree
        // environment is delivered through the PTY's startup environment so the
        // script (e.g. `cp "$SUPERSET_ROOT_PATH/.env" .env`) sees it directly.
        let panel = workspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: directory,
            initialInput: SupermuxCommandLaunch.shellInput(for: setupScript),
            startupEnvironment: request.setupEnvironment
        )
        if panel == nil {
            Self.logger.warning("setup script dropped: setup terminal failed to spawn in workspace \(workspace.id, privacy: .public)")
        }
    }

    /// Runs a project action's command as a new terminal tab in the focused
    /// workspace (the presets-bar behavior), not as a separate workspace. The
    /// command runs through the workspace's interactive shell (see
    /// ``SupermuxCommandLaunch``). With no focused workspace, falls back to
    /// opening a fresh workspace.
    func runAction(_ request: SupermuxOpenWorkspaceRequest) {
        guard let tabManager,
              let command = request.initialCommand,
              let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            openWorkspace(request)
            return
        }
        // Run where the user is looking: the focused workspace's directory (e.g.
        // a worktree), not the action's project root — matching ⌘G/presets.
        let resolved = SupermuxCommandLaunch.workingDirectory(
            focusedWorkspaceDirectory: workspace.currentDirectory, fallback: request.directory)
        let directory = (resolved as NSString).expandingTildeInPath
        guard let panel = workspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: directory,
            initialInput: SupermuxCommandLaunch.shellInput(for: command)
        ) else { return }
        // Open the action's tab as the first tab, matching the ⌘G run action.
        // The action runs in the foreground, so the new surface keeps focus.
        workspace.supermuxMoveSurfaceToFront(panelId: panel.id, keepFocus: true)
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

/// Builds the immutable ``SupermuxOpenWorkspace`` snapshot that a project-nested
/// sidebar row renders from a live ``Workspace``.
///
/// Extracted from ``SupermuxProjectsMount`` so the row's field mapping — most
/// importantly which source feeds the branch subtitle — is unit-testable
/// without a SwiftUI host. `projectId`/`isRunning` are passed in because they
/// depend on app-wide composition the caller already holds.
@MainActor
enum SupermuxWorkspaceRow {
    /// - Parameter includePullRequest: Pass `false` when cmux's PR polling /
    ///   visibility settings are off, so the row hides any briefly-lingering
    ///   badge just like cmux's own rows do (cmux clears the underlying state
    ///   when polling is disabled; this closes the stale window). Defaulted so
    ///   existing call sites and tests keep compiling.
    static func snapshot(
        for workspace: Workspace,
        isSelected: Bool,
        projectId: UUID?,
        isRunning: Bool,
        includePullRequest: Bool = true
    ) -> SupermuxOpenWorkspace {
        // Reuse cmux's own per-workspace PR probe for opened worktrees: the first
        // display-ordered PR is the representative one (cmux prioritizes
        // open > merged > closed and freshness). No supermux probe runs here.
        let pullRequest = includePullRequest
            ? workspace.sidebarPullRequestsInDisplayOrder().first
                .flatMap(SupermuxPullRequest.init(sidebarState:))
            : nil
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

    /// The cheap snapshot for a workspace no project owns. Standalone
    /// workspaces never render in the Projects section —
    /// `SupermuxProjectsSectionView` consumes only their `directory` (to
    /// exclude already-open worktrees from the unopened-worktree PR probe) —
    /// so this skips the branch/PR/activity resolution ``snapshot(for:isSelected:projectId:isRunning:)``
    /// pays, each leg of which walks the bonsplit pane tree.
    static func standaloneSnapshot(for workspace: Workspace, isSelected: Bool) -> SupermuxOpenWorkspace {
        SupermuxOpenWorkspace(
            id: workspace.id,
            title: workspace.customTitle ?? workspace.title,
            directory: workspace.currentDirectory,
            isSelected: isSelected
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

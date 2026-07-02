import AppKit
import Observation
import SupermuxKit

/// Drives the supermux run action (⌘G): starts and stops a per-workspace
/// dev-server command resolved from the workspace's project.
///
/// One coordinator serves the whole app (run state is keyed by workspace id),
/// owned by `SupermuxComposition`. The flow mirrors piggycode: the first ⌘G
/// launches the project's run commands in a dedicated terminal surface of the
/// active workspace; the next ⌘G sends Ctrl+C to stop it; ⌘G again re-runs
/// the command in the same surface.
///
/// `@Observable` so the presets bar's Run / Stop button reflects live run state:
/// reading ``isRunning(workspaceId:)`` in a view body subscribes it to the
/// `handlesByWorkspaceId` mutations that `toggleRun` performs.
///
/// Run state is reconciled against the run surface's *existence* (a closed
/// surface reads as not running), but is otherwise optimistic: the command
/// runs inside an interactive shell that survives its exit, so there is no
/// authoritative liveness signal for the command itself (Ghostty's
/// needs-confirm-quit heuristic is shell-integration- and config-dependent).
/// A dev server that exits on its own therefore still reads as running until
/// the next toggle or until its surface goes away.
@MainActor
@Observable
final class SupermuxRunCoordinator {
    private struct RunHandle {
        let workspaceId: UUID
        /// Weak so a closed workspace's handle reads as not running instead of
        /// keeping the workspace alive; also guards against a session-restored
        /// workspace reusing the persisted id of a stale handle.
        weak var workspace: Workspace?
        let panelId: UUID
        let command: String
        var isRunning: Bool

        /// `true` while the launched run surface still exists in its workspace.
        /// `@MainActor` because the nested struct does not inherit the
        /// coordinator's isolation and `Workspace.panels` is main-actor state.
        @MainActor var isRunningInLivePanel: Bool {
            isRunning && workspace?.panels[panelId] is TerminalPanel
        }
    }

    private var handlesByWorkspaceId: [UUID: RunHandle] = [:]
    @ObservationIgnored private let matcher = SupermuxProjectMatcher()
    @ObservationIgnored private let projectsModel: SupermuxProjectsModel

    /// Creates the coordinator.
    /// - Parameter projectsModel: Source of registered projects and their run commands.
    init(projectsModel: SupermuxProjectsModel) {
        self.projectsModel = projectsModel
    }

    /// Whether the workspace's run command is currently running, validated
    /// against the run surface's existence: a handle whose run surface (or
    /// whole workspace) has been closed reads as not running even before
    /// ``toggleRun`` or ``reconcile(workspace:)`` prunes it.
    /// Read-only, safe in view bodies.
    /// - Parameter workspaceId: Workspace to inspect.
    /// - Returns: `true` while the launched run surface exists and is active.
    func isRunning(workspaceId: UUID) -> Bool {
        handlesByWorkspaceId[workspaceId]?.isRunningInLivePanel ?? false
    }

    /// Drops the workspace's run handle when its run surface no longer exists,
    /// so closed-surface staleness is pruned eagerly instead of on the next
    /// ``toggleRun``. Mutates observable state — call from event-driven paths
    /// (e.g. a mount's `onAppear`), never from a view body.
    /// - Parameter workspace: Workspace whose handle to validate.
    func reconcile(workspace: Workspace) {
        guard let handle = handlesByWorkspaceId[workspace.id],
              !(workspace.panels[handle.panelId] is TerminalPanel) else { return }
        handlesByWorkspaceId[workspace.id] = nil
    }

    /// Whether a run-toggle key event may reach ``toggleRun(tabManager:)``.
    /// Auto-repeat events are rejected: repeat semantics suit the shared Find
    /// Next chord (hold ⌘G to step matches) but flap a start/stop toggle
    /// (start → Ctrl+C → restart …). A rejected event must fall through to
    /// the Find Next dispatch.
    /// - Parameter event: The key-down event that matched the run shortcut.
    /// - Returns: `true` when the event is an initial (non-repeat) key press.
    static func shouldDispatchRunToggle(for event: NSEvent) -> Bool {
        !event.isARepeat
    }

    /// Toggles the run command for the selected workspace (the ⌘G path).
    /// - Parameter tabManager: The active window's workspace manager.
    /// - Returns: `true` when the event was consumed (even to show an alert).
    @discardableResult
    func toggleRun(tabManager: TabManager?) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace else { return false }
        // ⌘G shares its chord with Find Next, so with no matching project the
        // event must fall through unconsumed — no feedback here (the
        // presets-bar path presents an alert instead).
        guard matchedProject(for: workspace) != nil else { return false }
        return toggleRun(workspace: workspace)
    }

    /// Toggles the run command for a specific workspace (the presets bar path).
    /// - Parameter workspace: The workspace whose run command to start/stop.
    /// - Returns: `true` when the event was consumed (even to show an alert).
    @discardableResult
    func toggleRun(workspace: Workspace) -> Bool {
        guard let project = matchedProject(for: workspace) else {
            presentMissingProject(directory: workspace.currentDirectory)
            return true
        }
        let command = project.runCommands
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " && ")

        if var handle = handlesByWorkspaceId[workspace.id],
           let panel = workspace.panels[handle.panelId] as? TerminalPanel {
            if handle.isRunning {
                // Stop: send a real Ctrl+C key event (SIGINT) through the panel
                // wrapper so a hibernated run surface is resumed first.
                // sendText() would route through ghostty_surface_text and get
                // wrapped in bracketed paste, turning the interrupt into literal
                // input.
                switch panel.sendNamedKeyResult("ctrl+c") {
                case .sent, .queued:
                    handle.isRunning = false
                    handlesByWorkspaceId[workspace.id] = handle
                case .surfaceUnavailable, .processExited:
                    // Nothing left to stop; drop the handle so the next toggle
                    // starts fresh instead of pasting into a dead surface.
                    handlesByWorkspaceId[workspace.id] = nil
                case .unknownKey, .inputQueueFull:
                    // The interrupt never reached the PTY: keep the run marked
                    // running so the next toggle retries the stop instead of
                    // pasting the command into the still-live server.
                    break
                }
                return true
            } else {
                guard !command.isEmpty else {
                    presentMissingRunCommand(project: project)
                    return true
                }
                // Restart in the same surface (the shell survives because run
                // surfaces are created with wait-after-command behavior). Paste
                // the command body, then press Return as a real key so the
                // shell executes it (a pasted newline would not, under bracketed
                // paste). Only mark running if the input was actually accepted;
                // otherwise drop the handle and spawn a fresh surface below.
                if panel.sendText(command) && panel.sendNamedKey("enter") {
                    handle.isRunning = true
                    handlesByWorkspaceId[workspace.id] = handle
                    panel.triggerFlash(reason: .navigation)
                    return true
                }
                handlesByWorkspaceId[workspace.id] = nil
            }
        }

        // No live run surface for this workspace yet.
        handlesByWorkspaceId[workspace.id] = nil
        guard !command.isEmpty else {
            presentMissingRunCommand(project: project)
            return true
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }
        // Capture the user's surface before opening the run surface so we can
        // keep focus on it: the run surface is launched in the background and
        // then moved to the front, and the move must not steal keyboard focus.
        let previousFocusedPanelId = workspace.focusedPanelId
        // Launch through the interactive shell (see SupermuxCommandLaunch), the
        // same path the restart branch above uses via sendText + Return: shell
        // aliases/functions resolve and the surface survives the command exit.
        guard let panel = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: workspace.currentDirectory,
            initialInput: SupermuxCommandLaunch.shellInput(for: command)
        ) else {
            return false
        }
        // Always place the run surface as the first tab instead of at the end of
        // the pane's tab bar, so the project's dev-server lives in a predictable
        // spot. keepFocus: false re-focuses the user's surface after the move, so
        // it lands at the front in the background without stealing focus.
        workspace.supermuxMoveSurfaceToFront(
            panelId: panel.id,
            keepFocus: false,
            restoreFocusTo: previousFocusedPanelId
        )
        handlesByWorkspaceId[workspace.id] = RunHandle(
            workspaceId: workspace.id,
            workspace: workspace,
            panelId: panel.id,
            command: command,
            isRunning: true
        )
        panel.triggerFlash(reason: .navigation)
        return true
    }

    private func matchedProject(for workspace: Workspace) -> SupermuxProject? {
        matcher.project(for: workspace.currentDirectory, in: projectsModel.projects)
    }

    private func presentMissingProject(directory: String) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.run.noProject.title",
            defaultValue: "No project for this folder"
        )
        alert.informativeText = String(
            localized: "supermux.run.noProject.message",
            defaultValue: "“\(directory)” is not part of any registered project. Add the folder in the Projects sidebar section to configure its run commands."
        )
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func presentMissingRunCommand(project: SupermuxProject) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.run.missingCommand.title",
            defaultValue: "No run command configured"
        )
        alert.informativeText = String(
            localized: "supermux.run.missingCommand.message",
            defaultValue: "Add run commands to “\(project.name)” via its Edit Project… sheet in the Projects sidebar section."
        )
        alert.alertStyle = .informational
        alert.runModal()
    }
}

extension Workspace {
    /// Moves a freshly opened supermux surface to the front (index 0) of its
    /// pane, so the ⌘G run action and project run-action commands open their
    /// terminal as the *first* tab instead of being appended at the end.
    ///
    /// bonsplit's reorder always selects and focuses the moved tab, so:
    /// - `keepFocus == true` (foreground actions) is a single reorder — the new
    ///   surface stays selected and focused at the front.
    /// - `keepFocus == false` (the background ⌘G run path) reorders, then
    ///   re-focuses `restoreFocusTo` as the final selection so the run tab lands
    ///   at the front without stealing keyboard focus from the surface the user
    ///   was on. Capture `restoreFocusTo` (the workspace's `focusedPanelId`)
    ///   *before* opening the new surface.
    ///
    /// Note: when the pane has pinned tabs, "front" is the first *unpinned* slot,
    /// since pinned tabs always precede unpinned ones in a pane.
    func supermuxMoveSurfaceToFront(panelId: UUID, keepFocus: Bool, restoreFocusTo: UUID? = nil) {
        reorderSurface(panelId: panelId, toIndex: 0, focus: keepFocus)
        guard !keepFocus,
              let restoreFocusTo,
              restoreFocusTo != panelId,
              panels[restoreFocusTo] != nil else { return }
        focusPanel(restoreFocusTo)
    }
}

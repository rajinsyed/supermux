import AppKit
import SupermuxKit

/// Drives the supermux run action (⌘G): starts and stops a per-workspace
/// dev-server command resolved from the workspace's project.
///
/// One coordinator serves the whole app (run state is keyed by workspace id),
/// owned by `SupermuxComposition`. The flow mirrors piggycode: the first ⌘G
/// launches the project's run commands in a dedicated terminal surface of the
/// active workspace; the next ⌘G sends Ctrl+C to stop it; ⌘G again re-runs
/// the command in the same surface.
@MainActor
final class SupermuxRunCoordinator {
    private struct RunHandle {
        let workspaceId: UUID
        let panelId: UUID
        let command: String
        var isRunning: Bool
    }

    private var handlesByWorkspaceId: [UUID: RunHandle] = [:]
    private let matcher = SupermuxProjectMatcher()
    private let projectsModel: SupermuxProjectsModel

    /// Creates the coordinator.
    /// - Parameter projectsModel: Source of registered projects and their run commands.
    init(projectsModel: SupermuxProjectsModel) {
        self.projectsModel = projectsModel
    }

    /// Toggles the run command for the selected workspace.
    /// - Parameter tabManager: The active window's workspace manager.
    /// - Returns: `true` when the event was consumed (even to show an alert).
    @discardableResult
    func toggleRun(tabManager: TabManager?) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace else { return false }
        guard let project = matcher.project(for: workspace.currentDirectory, in: projectsModel.projects) else {
            return false
        }
        let command = project.runCommands
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " && ")

        if var handle = handlesByWorkspaceId[workspace.id],
           let panel = workspace.panels[handle.panelId] as? TerminalPanel {
            if handle.isRunning {
                // Stop: send a real Ctrl+C key event (SIGINT). sendText() would
                // route through ghostty_surface_text and get wrapped in
                // bracketed paste, turning the interrupt into literal input.
                _ = panel.surface.sendNamedKey("ctrl+c")
                handle.isRunning = false
                handlesByWorkspaceId[workspace.id] = handle
            } else {
                guard !command.isEmpty else {
                    presentMissingRunCommand(project: project)
                    return true
                }
                // Restart in the same surface (the shell survives because run
                // surfaces are created with wait-after-command behavior). Paste
                // the command body, then press Return as a real key so the
                // shell executes it (a pasted newline would not, under
                // bracketed paste).
                _ = panel.surface.sendText(command)
                _ = panel.surface.sendNamedKey("enter")
                handle.isRunning = true
                handlesByWorkspaceId[workspace.id] = handle
                panel.triggerFlash(reason: .navigation)
            }
            return true
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
        guard let panel = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: workspace.currentDirectory,
            initialCommand: command
        ) else {
            return false
        }
        handlesByWorkspaceId[workspace.id] = RunHandle(
            workspaceId: workspace.id,
            panelId: panel.id,
            command: command,
            isRunning: true
        )
        panel.triggerFlash(reason: .navigation)
        return true
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

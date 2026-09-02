import AppKit
import CmuxSettings
import Foundation
import SupermuxKit

/// Presents one file's patch from the Changes panel in cmux's diff viewer.
///
/// The captured patch is piped to the bundled `cmux diff -` CLI, which renders
/// it in the same browser-hosted viewer (syntax highlighting, split/unified
/// layout, comments) that the panel's "Open Diff" header button and the Open
/// Diff Viewer shortcut use — one viewer path, scoped here to a single file
/// and side. The viewer lands as a browser tab to the right of the
/// workspace's focused surface; a later click replaces the tab this opener
/// last opened in that workspace instead of stacking one tab per file.
@MainActor
final class SupermuxFileDiffOpener {
    static let shared = SupermuxFileDiffOpener()

    /// The viewer surface this opener last opened, per workspace id.
    private var openedSurfaces: [UUID: UUID] = [:]
    /// CLI processes still running, keyed by pid, so they are retained until exit.
    private var processes: [Int32: Process] = [:]

    /// Opens `patch` for the selected workspace of `tabManager`.
    /// - Returns: `false` when there is no workspace or no bundled CLI (the
    ///   caller beeps); a CLI failure after launch beeps on its own.
    @discardableResult
    func present(_ patch: SupermuxFileDiffPatch, for tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.selectedWorkspace,
              let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            return false
        }
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let workspaceId = workspace.id
        // Forget a remembered viewer the user already closed.
        let previousSurface = openedSurfaces[workspaceId].flatMap { workspace.panels[$0] != nil ? $0 : nil }
        openedSurfaces[workspaceId] = previousSurface
        let sourceSurface = Self.sourceSurface(in: workspace, excluding: previousSurface)

        let process = Process()
        process.executableURL = cliURL
        var arguments = [
            "--socket", socketPath,
            // `--id-format uuids`: the JSON must carry `surface_id` (the default
            // ref format reports only `surface_ref`).
            "diff", "-", "--json", "--id-format", "uuids",
            "--title", patch.title,
            "--cwd", patch.repoPath,
            "--workspace", workspaceId.uuidString,
            "--focus", "false",
        ]
        if let sourceSurface {
            arguments += ["--surface", sourceSurface.uuidString]
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment["CMUX_WORKSPACE_ID"] = workspaceId.uuidString
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
#if DEBUG
            cmuxDebugLog("supermux.fileDiff.open failed errorType=\(type(of: error))")
#endif
            return false
        }
        let pid = process.processIdentifier
        processes[pid] = process

        let patchData = Data(patch.patch.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            // The CLI reads stdin to EOF before it does anything else, so the
            // write completes before any output is produced. A CLI that died
            // early would turn the write into SIGPIPE — which kills the whole
            // app — so the pipe is marked no-SIGPIPE and the write just fails.
            let writer = stdinPipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? writer.write(contentsOf: patchData)
            try? writer.close()
            let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrByteCount = stderrPipe.fileHandleForReading.readDataToEndOfFile().count
            process.waitUntilExit()
            let status = process.terminationStatus
            Task { @MainActor [weak self, weak workspace] in
                self?.processes.removeValue(forKey: pid)
                guard status == 0, let workspace, let self else {
#if DEBUG
                    // Metadata only: the CLI's output can echo repo paths.
                    cmuxDebugLog("supermux.fileDiff.open exited status=\(status) stderrBytes=\(stderrByteCount)")
#endif
                    if status != 0 { NSSound.beep() }
                    return
                }
                self.replacePreviousViewer(
                    in: workspace,
                    previousSurface: previousSurface,
                    openedSurface: Self.openedSurfaceId(fromCLIOutput: stdout)
                )
            }
        }
        return true
    }

    /// Records the viewer the CLI just opened and closes the one it replaces.
    /// Runs only after the new tab exists, so the pane never collapses between
    /// the two.
    private func replacePreviousViewer(in workspace: Workspace, previousSurface: UUID?, openedSurface: UUID?) {
        openedSurfaces[workspace.id] = openedSurface
        guard let previousSurface, previousSurface != openedSurface,
              workspace.panels[previousSurface] != nil else { return }
        _ = workspace.closePanel(previousSurface, force: true)
    }

    /// The surface to split from. The focused surface, unless that is the
    /// viewer about to be replaced — then any non-browser surface, so the
    /// replacement lands in the old viewer's pane (the nearest right-side
    /// pane) instead of splitting to the right of it.
    private static func sourceSurface(in workspace: Workspace, excluding previousSurface: UUID?) -> UUID? {
        if let focused = workspace.focusedPanelId, focused != previousSurface {
            return focused
        }
        return workspace.panels
            .first { id, panel in id != previousSurface && !(panel is BrowserPanel) }?
            .key
    }

    /// The `surface_id` from `cmux diff --json` output; `nil` when absent or
    /// unparseable (the opener then simply stops tracking a viewer to replace).
    nonisolated static func openedSurfaceId(fromCLIOutput output: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let id = object["surface_id"] as? String else { return nil }
        return UUID(uuidString: id)
    }
}

import AppKit
import CmuxSettings
import Foundation
import SupermuxKit
#if DEBUG
import CMUXDebugLog
#endif

/// Presents one file's patch from the Changes panel in cmux's diff viewer.
///
/// The captured patch is piped to the bundled `cmux diff -` CLI, which renders
/// it in the same browser-hosted viewer (syntax highlighting, split/unified
/// layout, comments) that the panel's "Open Diff" header button and the Open
/// Diff Viewer shortcut use — one viewer path, scoped here to a single file
/// and side. The viewer lands as a browser tab to the right of the
/// workspace's focused surface; a later click replaces the tab this opener
/// last opened in that workspace instead of stacking one tab per file.
///
/// One CLI open runs per workspace at a time (its surface id only arrives on
/// exit). Clicks during that flight are queued latest-wins by
/// ``SupermuxFileDiffOpenQueue`` and launched when it ends, so rapid clicks
/// always end on the last file clicked with a single viewer tab.
@MainActor
final class SupermuxFileDiffOpener {
    static let shared = SupermuxFileDiffOpener()

    private var queue = SupermuxFileDiffOpenQueue()
    /// CLI processes still running, keyed by pid, so they are retained until exit.
    private var processes: [Int32: Process] = [:]

    /// Opens `patch` for the selected workspace of `tabManager`.
    /// - Returns: `false` when there is no workspace or no bundled CLI (the
    ///   caller beeps); a CLI failure after launch beeps on its own.
    @discardableResult
    func present(_ patch: SupermuxFileDiffPatch, for tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.selectedWorkspace, Self.cliURL != nil else { return false }
        // An open already running here: the click is queued (latest wins) and
        // launches from `complete` once the CLI returns.
        guard queue.requestOpen(patch, in: workspace.id) else { return true }
        return launch(patch, in: workspace)
    }

    /// The bundled CLI, or `nil` when the bundle ships none.
    private static var cliURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Starts the CLI for a request the queue marked in flight.
    private func launch(_ patch: SupermuxFileDiffPatch, in workspace: Workspace) -> Bool {
        guard let cliURL = Self.cliURL else {
            _ = queue.abandonOpen(in: workspace.id)
            return false
        }
        let workspaceId = workspace.id
        let state = queue.state(for: workspaceId)
        // Forget a remembered viewer the user already closed.
        let previousSurface = state.openedSurface.flatMap { workspace.panels[$0] != nil ? $0 : nil }
        let sourceSurface = Self.sourceSurface(
            in: workspace, remembered: state.sourceSurface, excluding: previousSurface
        )
        queue.recordLaunch(previousSurface: previousSurface, sourceSurface: sourceSurface, in: workspaceId)

        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
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

        let patchData = Data(patch.patch.utf8)
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
            // A launch that cannot even start will not start for the queued
            // click either; drop it rather than loop.
            _ = queue.abandonOpen(in: workspaceId)
            return false
        }
        let pid = process.processIdentifier
        processes[pid] = process
#if DEBUG
        cmuxDebugLog(
            "supermux.fileDiff.open pid=\(pid) staged=\(patch.staged ? 1 : 0) "
                + "patchBytes=\(patchData.count) source=\(sourceSurface?.uuidString.prefix(5) ?? "nil") "
                + "previous=\(previousSurface?.uuidString.prefix(5) ?? "nil")"
        )
#endif

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
            let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let status = process.terminationStatus
            Task { @MainActor [weak self, weak workspace] in
                self?.processes.removeValue(forKey: pid)
#if DEBUG
                if status != 0 {
                    // Debug builds log a bounded stderr prefix (it can name repo
                    // paths, so this stays out of release logging).
                    let stderrPrefix = String(decoding: stderr.prefix(240), as: UTF8.self)
                        .replacingOccurrences(of: "\n", with: " ")
                    cmuxDebugLog("supermux.fileDiff.open exited status=\(status) stderr=\(stderrPrefix)")
                    Self.appendDiagnostics(
                        "exit status=\(status) socket=\(socketPath) args=\(arguments.joined(separator: " ")) "
                            + "stderr=\(stderrPrefix)"
                    )
                }
#endif
                self?.complete(
                    workspaceId: workspaceId, workspace: workspace, status: status,
                    stdout: stdout, previousSurface: previousSurface
                )
            }
        }
        return true
    }

    /// Ends the flight: records the viewer the CLI opened and closes the one
    /// it replaces (only now, when the new tab exists, so the pane never
    /// collapses between the two), then launches the click queued meanwhile.
    private func complete(
        workspaceId: UUID, workspace: Workspace?, status: Int32, stdout: Data, previousSurface: UUID?
    ) {
        let next: SupermuxFileDiffPatch?
        if status == 0 {
            let openedSurface = Self.openedSurfaceId(fromCLIOutput: stdout)
            next = queue.finishOpen(in: workspaceId, openedSurface: openedSurface)
#if DEBUG
            cmuxDebugLog(
                "supermux.fileDiff.opened surface=\(openedSurface?.uuidString.prefix(5) ?? "nil") "
                    + "replacing=\(previousSurface?.uuidString.prefix(5) ?? "nil")"
            )
#endif
            if let workspace, let previousSurface, previousSurface != openedSurface,
               workspace.panels[previousSurface] != nil {
                _ = workspace.closePanel(previousSurface, force: true)
            }
        } else {
            next = queue.abandonOpen(in: workspaceId)
            NSSound.beep()
        }
        guard let next else { return }
        guard let workspace else {
            _ = queue.abandonOpen(in: workspaceId)
            return
        }
        _ = launch(next, in: workspace)
    }

    /// The surface to split from: the focused surface, unless that is the
    /// viewer about to be replaced. Then the pane the viewer was originally
    /// split from, while it exists, so the replacement lands in the old
    /// viewer's spot even with several terminal splits — and failing that any
    /// non-browser surface.
    private static func sourceSurface(
        in workspace: Workspace, remembered: UUID?, excluding previousSurface: UUID?
    ) -> UUID? {
        if let focused = workspace.focusedPanelId, focused != previousSurface {
            return focused
        }
        if let remembered, remembered != previousSurface, workspace.panels[remembered] != nil {
            return remembered
        }
        return workspace.panels
            .first { id, panel in id != previousSurface && !(panel is BrowserPanel) }?
            .key
    }

#if DEBUG
    /// Debug-build diagnostics beside the debug event log (the same file the
    /// event log resolved, so a tagged build's `/tmp/cmux-debug-<tag>.log`
    /// gets a matching `.filediff` sibling), unredacted: the event log masks
    /// any value containing a path, which hides the CLI's error text. Never
    /// compiled into release builds.
    nonisolated private static func appendDiagnostics(_ line: String) {
        let url = URL(fileURLWithPath: DebugEventLog.currentLogPath() + ".filediff")
        let text = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
#endif

    /// The `surface_id` from `cmux diff --json` output; `nil` when absent or
    /// unparseable (the opener then simply stops tracking a viewer to replace).
    nonisolated static func openedSurfaceId(fromCLIOutput output: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let id = object["surface_id"] as? String else { return nil }
        return UUID(uuidString: id)
    }
}

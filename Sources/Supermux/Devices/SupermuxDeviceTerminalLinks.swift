import AppKit
import Bonsplit
import CMUXMobileCore
import CmuxSurfaceCatalogModel
import CmuxTerminalCore
import Foundation

/// Cmd-click on a file path in another Mac's terminal (a device mirror pane).
///
/// Upstream refused it: only an SSH terminal resolved a clicked path on the
/// machine that runs it, and a path in any other remote terminal must never
/// open a file of the same name on this Mac. A device mirror resolves the
/// path the way the owning Mac's own terminal would (against that terminal's
/// folder, which the Mac reports per terminal in its workspace records, and
/// `~` against that Mac's home) and opens the file in the mirror's read-only
/// preview, read over `supermux.files_read.v1` like the mirror's Files panel.
/// A clicked folder opens nothing. URLs never come here (the link coordinator
/// sends only file references), so they keep opening as before.
///
/// The preview reads only inside the workspace's folder on that Mac (the
/// files RPCs are confined to it), so a file outside it says so; a Mac that
/// is not connected or runs a Supermux without file reads says that instead.
/// Used by the `device-terminal-file-link` touchpoint in
/// `Workspace+TerminalLinkOpening.swift`.
@MainActor
enum SupermuxDeviceTerminalLinks {
    /// One store per mirror workspace, holding the preview's provider and cache
    /// (it never lists anything: the panel's own store does that).
    private static var stores: [UUID: FileExplorerStore] = [:]

    /// Opens `rawValue` clicked in terminal `panelID` of `workspace` on the Mac
    /// that runs the terminal. Returns `false` when another Mac does not run
    /// it (the click is not this type's); `true` once the click is handled,
    /// even when nothing could be opened.
    static func open(_ rawValue: String, panelID: UUID, in workspace: Workspace) -> Bool {
        guard let projection = SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: panelID),
              projection.resource.machine.isDevice else { return false }
        guard let target = SupermuxComposition.mirrorResolver.target(for: workspace),
              target.machine == projection.resource.machine else {
            // A device terminal outside its mirror has no folder to read from.
            NSSound.beep()
            return true
        }
        let root: SupermuxMirrorFileRoot
        switch SupermuxMirrorFileExplorerRoot.root(for: workspace) {
        case .supermuxDevice(let resolved)?:
            root = resolved
        case .remoteCloud(_, _, _, _, _, let detail, _)?:
            present(detail ?? SupermuxDeviceError.notConnected(target.deviceName).errorDescription, workspace: workspace)
            return true
        default:
            return true
        }
        let directory = terminalDirectory(remoteSurfaceID: projection.resource.key, target: target) ?? root.rootPath
        let pane = workspace.paneId(forPanelId: panelID)
        Task { await openFile(rawValue, directory: directory, root: root, workspace: workspace, pane: pane) }
        return true
    }

    // MARK: - Resolution

    /// The folder the owning Mac reports for that terminal.
    private static func terminalDirectory(remoteSurfaceID: String, target: SupermuxMirrorTarget) -> String? {
        let record = SupermuxComposition.devices.record(for: target.ref)
        let terminal = record?.terminals.first { $0.id.caseInsensitiveCompare(remoteSurfaceID) == .orderedSame }
        guard let directory = terminal?.currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              directory.hasPrefix("/") else { return nil }
        return directory
    }

    /// Absolute paths on the owning Mac the click may name, in preference
    /// order: the literal spelling first, then without a `:line[:column]`
    /// suffix (a file literally named `notes:2` wins over `notes` line 2).
    static func candidates(_ rawValue: String, directory: String, home: String?) -> [String] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens = [trimmed]
        if let stripped = strippingLocation(trimmed) { tokens.append(stripped) }
        return RemoteTerminalPathResolver().candidates(
            tokens: tokens, workingDirectory: directory, homeDirectory: home, remoteHost: ""
        ).map { URL(fileURLWithPath: $0).standardized.path }
    }

    /// `path:12` or `path:12:5` without the location, or nil.
    private static func strippingLocation(_ token: String) -> String? {
        var parts = token.split(separator: ":", omittingEmptySubsequences: false)
        var removed = 0
        while removed < 2, parts.count > 1, let last = parts.last, Int(last).map({ $0 > 0 }) == true {
            parts.removeLast()
            removed += 1
        }
        guard removed > 0 else { return nil }
        let path = parts.joined(separator: ":")
        return path.isEmpty ? nil : path
    }

    // MARK: - Open

    private static func openFile(
        _ rawValue: String,
        directory: String,
        root: SupermuxMirrorFileRoot,
        workspace: Workspace,
        pane: PaneID?
    ) async {
        let store = store(for: root)
        guard let provider = store.provider as? SupermuxDeviceFileExplorerProvider else { return }
        let home = try? await provider.resolveHomePath()
        var outsideFolder = false
        for path in candidates(rawValue, directory: directory, home: home) {
            guard path != root.rootPath else { return } // the folder itself
            switch await kind(of: path, provider: provider) {
            case .file:
                guard let pane = pane ?? workspace.bonsplitController.focusedPaneId else { return }
                FileExplorerPreviewCoordinator(store: store).open(
                    path: path, workspace: workspace, pane: pane,
                    isCurrent: { [weak workspace] in workspace.map { !$0.isRetiredFromOwningTabManager } ?? false }
                )
                return
            case .directory:
                return
            case .outsideFolder:
                outsideFolder = true
            case .missing:
                continue
            }
        }
        if outsideFolder {
            present(SupermuxDeviceFileError.outsideFolder(deviceName: root.deviceName).errorDescription, workspace: workspace)
        } else {
            NSSound.beep()
        }
    }

    private enum Kind { case file, directory, outsideFolder, missing }

    /// What `path` names over there, from its parent folder's listing.
    private static func kind(of path: String, provider: SupermuxDeviceFileExplorerProvider) async -> Kind {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        do {
            let entries = try await provider.listDirectory(path: parent, showHidden: true)
            guard let entry = entries.first(where: { $0.name == name }) else { return .missing }
            return entry.isDirectory ? .directory : .file
        } catch let error as SupermuxDeviceFileError {
            if case .outsideFolder = error { return .outsideFolder }
            return .missing
        } catch {
            return .missing
        }
    }

    /// The workspace's preview store, with a provider for `root`.
    private static func store(for root: SupermuxMirrorFileRoot) -> FileExplorerStore {
        stores = stores.filter { Workspace.liveWorkspace(id: $0.key) != nil }
        let store = stores[root.workspaceID] ?? FileExplorerStore()
        stores[root.workspaceID] = store
        if (store.provider as? SupermuxDeviceFileExplorerProvider)?.root != root {
            store.setWorkspaceRootIdentity(root.workspaceID)
            store.setProvider(
                SupermuxDeviceFileExplorerProvider(root: root, devices: SupermuxComposition.devices),
                reloadIfAvailable: false
            )
        }
        return store
    }

    private static func present(_ message: String?, workspace: Workspace) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "fileExplorer.preview.failedTitle", defaultValue: "Unable to open remote file")
        alert.informativeText = message ?? ""
        alert.addButton(withTitle: String(localized: "fileExplorer.preview.ok", defaultValue: "OK"))
        SupermuxAlertPresentation.show(alert, preferring: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
    }
}

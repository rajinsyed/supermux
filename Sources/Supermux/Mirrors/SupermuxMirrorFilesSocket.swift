import Bonsplit
import CryptoKit
import Foundation

/// `supermux.devices.mirror.files` (DEBUG builds only): drives the Files
/// panel a window shows for a workspace, through the SAME code the panel runs.
/// The driver keeps its own `FileExplorerStore` per workspace and syncs it the
/// way the right sidebar does (`showHiddenFiles = true`, `syncWorkspaceRoot`),
/// so the resolver, the provider, the follow-the-folder observation and the
/// live refresh are the real ones; it never reads this Mac's disk for a mirror.
///
/// `{workspace_id, action, path?, query?, timeout_seconds?}` where `action` is:
/// - `state` — resolver kind, provider kind, root, header text, status message,
///   loaded rows (expanded children nested), git decorations (root-relative).
/// - `expand {path}` — `store.expand(node:)`, waits for the children or an error.
/// - `open {path}` — the double-click path (`FileExplorerPreviewCoordinator.open`),
///   waits for the preview panel of that remote path.
/// - `materialize {path}` — the preview download alone, so a failure is a
///   reply, never the coordinator's modal alert.
/// - `search {query}` — the Find tool's controller with the store's scope.
/// - `local_rows {path}` / `local_git_status {path}` — what THIS Mac's own
///   Files panel shows for a folder (the loopback's files are on this disk too).
/// - `unmount` — drops the driver's store (its observation and refresh go with it).
@MainActor
enum SupermuxMirrorFilesSocket {
    #if DEBUG
    /// The driver's stores, one per workspace (a window's panel keeps one store).
    private static var stores: [UUID: FileExplorerStore] = [:]
    #endif

    static func handle(_ params: [String: Any], workspace: Workspace) async throws -> [String: Any] {
        #if DEBUG
        let timeout = timeoutDuration(params)
        switch params["action"] as? String ?? "state" {
        case "state":
            let store = mount(workspace)
            await settle(store, timeout: .seconds(min(5, timeout.components.seconds)))
            return describe(store, workspace: workspace)
        case "expand":
            let store = mount(workspace)
            await settle(store, timeout: timeout)
            let path = try SupermuxMirrorSocketCommands.string(params, "path")
            guard let node = findNode(path, in: store.rootNodes) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "no loaded row at \(path)")
            }
            store.expand(node: node)
            try await waitUntil(timeout) { node.children != nil || node.error != nil }
            return ["node": row(node, root: store.rootPath), "state": describe(store, workspace: workspace)]
        case "open":
            return try await open(params, store: mount(workspace), workspace: workspace, timeout: timeout)
        case "materialize":
            return await materialize(try SupermuxMirrorSocketCommands.string(params, "path"), store: mount(workspace))
        case "search":
            return try await search(try SupermuxMirrorSocketCommands.string(params, "query"), store: mount(workspace), timeout: timeout)
        case "local_rows":
            return try await localRows(try SupermuxMirrorSocketCommands.string(params, "path"), timeout: timeout)
        case "local_git_status":
            let path = try SupermuxMirrorSocketCommands.string(params, "path")
            let status = await Task.detached { GitStatusProvider().fetchStatus(directory: path) }.value
            return ["git_status": relativeStatus(status, root: path)]
        case "unmount":
            stores[workspace.id]?.applyWorkspaceRoot(.none)
            return ["unmounted": stores.removeValue(forKey: workspace.id) != nil]
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(
                message: "action must be state, expand, open, materialize, search, local_rows, local_git_status or unmount"
            )
        }
        #else
        throw SupermuxMirrorSocketCommands.InvalidParams(message: "mirror.files is a DEBUG driver")
        #endif
    }

    #if DEBUG
    // MARK: - Store

    /// The workspace's store, synced like the right sidebar's on every call.
    private static func mount(_ workspace: Workspace) -> FileExplorerStore {
        let store = stores[workspace.id] ?? FileExplorerStore()
        stores[workspace.id] = store
        store.showHiddenFiles = true
        store.syncWorkspaceRoot(from: workspace)
        return store
    }

    private static func settle(_ store: FileExplorerStore, timeout: Duration) async {
        try? await waitUntil(timeout) { !store.isRootLoading && store.loadingPaths.isEmpty }
    }

    private static func waitUntil(_ timeout: Duration, _ done: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !done() {
            guard clock.now < deadline else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func describe(_ store: FileExplorerStore, workspace: Workspace) -> [String: Any] {
        let resolved = SupermuxMirrorLocalPathActions.describe(workspace)["file_explorer"] ?? NSNull()
        return [
            "resolved": resolved,
            "provider_kind": providerKind(store.provider),
            "provider_available": store.provider?.isAvailable ?? false,
            "remote_identity": (store.provider as? any RemoteFileExplorerProvider)?.remoteIdentity ?? NSNull(),
            "search_scope": FileSearchScope(provider: store.provider).debugName,
            "root_path": store.rootPath,
            "display_root_path": store.displayRootPath,
            "status_message": store.rootStatusMessage ?? NSNull(),
            "is_loading": store.isRootLoading || !store.loadingPaths.isEmpty,
            "rows": store.rootNodes.map { row($0, root: store.rootPath) },
            "git_status": relativeStatus(store.gitStatusByPath, root: store.rootPath),
        ]
    }

    /// Which provider backs the panel, without naming fork types the driver
    /// predates: a device provider is recognised by its remote identity.
    private static func providerKind(_ provider: FileExplorerProvider?) -> String {
        guard let provider else { return "none" }
        switch provider {
        case is LocalFileExplorerProvider: return "local"
        case is SSHFileExplorerProvider: return "ssh"
        case is CloudVMFileExplorerProvider: return "cloud"
        case let remote as any RemoteFileExplorerProvider:
            return remote.remoteIdentity.hasPrefix("supermux-device:") ? "device" : "remote"
        default: return "other"
        }
    }

    private static func row(_ node: FileExplorerNode, root: String) -> [String: Any] {
        var payload: [String: Any] = [
            "name": node.name,
            "path": node.path,
            "relative_path": relative(node.path, root: root),
            "is_directory": node.isDirectory,
            "is_loading": node.isLoading,
            "error": node.error ?? NSNull(),
        ]
        if let children = node.children {
            payload["children"] = children.map { row($0, root: root) }
        }
        return payload
    }

    private static func findNode(_ path: String, in nodes: [FileExplorerNode]) -> FileExplorerNode? {
        for node in nodes {
            if node.path == path { return node }
            if let children = node.children, let found = findNode(path, in: children) { return found }
        }
        return nil
    }

    private static func relative(_ path: String, root: String) -> String {
        guard !root.isEmpty else { return path }
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func relativeStatus(_ status: [String: GitFileStatus], root: String) -> [String: String] {
        var result: [String: String] = [:]
        for (path, value) in status { result[relative(path, root: root)] = String(describing: value) }
        return result
    }

    // MARK: - Open / preview

    private static func open(
        _ params: [String: Any],
        store: FileExplorerStore,
        workspace: Workspace,
        timeout: Duration
    ) async throws -> [String: Any] {
        await settle(store, timeout: timeout)
        let path = try SupermuxMirrorSocketCommands.string(params, "path")
        // The coordinator reports a failed download in a modal alert, which
        // would block the socket: prove the download works first.
        let probe = await materialize(path, store: store)
        guard probe["ok"] as? Bool == true else { return ["opened": false, "probe": probe] }
        guard let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "the workspace has no pane")
        }
        FileExplorerPreviewCoordinator(store: store).open(path: path, workspace: workspace, pane: pane, isCurrent: { true })
        var panel: FilePreviewPanel?
        try await waitUntil(timeout) {
            panel = previewPanels(workspace, remotePath: path).first
            return panel != nil
        }
        guard let panel else { return ["opened": false] }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: panel.filePath))) ?? Data()
        return [
            "opened": true,
            "panel_id": panel.id.uuidString,
            "read_only": panel.cloudPreviewLease != nil,
            "provider_identity": panel.cloudPreviewProviderIdentity ?? NSNull(),
            "sha256": sha256(data),
            "panel_count": previewPanels(workspace, remotePath: path).count,
            "focused_panel_id": workspace.focusedPanelId?.uuidString ?? NSNull(),
        ]
    }

    private static func previewPanels(_ workspace: Workspace, remotePath: String) -> [FilePreviewPanel] {
        workspace.panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .filter { !$0.isClosed && $0.cloudPreviewRemotePath == remotePath }
    }

    private static func materialize(_ path: String, store: FileExplorerStore) async -> [String: Any] {
        guard let provider = store.provider as? any RemoteFileExplorerProvider, provider.isAvailable else {
            return ["ok": false, "error": "the panel has no available remote provider"]
        }
        do {
            let lease = try await store.cloudPreviewCache.materialize(path: path, provider: provider)
            let data = withExtendedLifetime(lease) { (try? Data(contentsOf: lease.url)) ?? Data() }
            return ["ok": true, "size": data.count, "sha256": sha256(data)]
        } catch {
            return ["ok": false, "error": error.localizedDescription, "error_type": String(describing: type(of: error))]
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Search

    private static func search(_ query: String, store: FileExplorerStore, timeout: Duration) async throws -> [String: Any] {
        await settle(store, timeout: timeout)
        let scope = FileSearchScope(provider: store.provider)
        let controller = FileSearchController()
        var latest = FileSearchSnapshot.empty
        controller.onSnapshotChanged = { latest = $0 }
        controller.search(query: query, rootPath: store.rootPath, scope: scope)
        defer { controller.cancel(clear: false) }
        try await waitUntil(timeout) { !latest.isSearching && latest.status != .searching && latest.status != .idle }
        return [
            "scope": scope.debugName,
            "status": statusName(latest.status),
            "status_detail": statusDetail(latest.status),
            "results": latest.results.map { result in
                [
                    "path": result.path,
                    "relative_path": result.relativePath,
                    "line": result.lineNumber,
                    "column": result.columnNumber,
                    "preview": result.preview,
                ] as [String: Any]
            },
        ]
    }

    private static func statusName(_ status: FileSearchSnapshot.Status) -> String {
        switch status {
        case .idle: return "idle"
        case .unsupported: return "unsupported"
        case .searching: return "searching"
        case .noMatches: return "no_matches"
        case .matches: return "matches"
        case .limited: return "limited"
        case .failed: return "failed"
        }
    }

    private static func statusDetail(_ status: FileSearchSnapshot.Status) -> Any {
        switch status {
        case .limited(let count): return count
        case .failed(let message): return message
        default: return NSNull()
        }
    }

    // MARK: - This Mac's own panel

    /// The rows THIS Mac's Files panel lists for `path`: a local store, synced
    /// like the right sidebar's, with `children` for every loaded folder.
    private static func localRows(_ path: String, timeout: Duration) async throws -> [String: Any] {
        let store = FileExplorerStore()
        store.showHiddenFiles = true
        store.applyWorkspaceRoot(.local(workspaceId: UUID(), path: path))
        defer { store.applyWorkspaceRoot(.none) }
        await settle(store, timeout: timeout)
        return ["root_path": store.rootPath, "rows": store.rootNodes.map { row($0, root: store.rootPath) }]
    }

    private static func timeoutDuration(_ params: [String: Any]) -> Duration {
        let seconds = min(max((params["timeout_seconds"] as? NSNumber)?.doubleValue ?? 20, 1), 120)
        return .milliseconds(Int(seconds * 1000))
    }
    #endif
}

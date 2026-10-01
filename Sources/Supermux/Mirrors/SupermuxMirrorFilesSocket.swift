import AppKit
import Bonsplit
import Combine
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
///   loaded rows (expanded children nested), git decorations (root-relative),
///   expanded paths and the selected path.
/// - `counters {reset?}` — how often the panel refreshed visibly since the
///   last reset, without waiting for it to settle: `emptied` (the rows went
///   away), `loading_shown` (the spinner came up), `rebuilt` (the rows were
///   rebuilt) and `git_published` (git colors were published), plus
///   `refreshes` (live refreshes run, changed or not: re-listing and git
///   status over the link) and `since_seconds`. `reset: true` zeroes them
///   after the reply is built.
/// - `expand {path}` — `store.expand(node:)`, waits for the children or an error.
/// - `open {path, probe?}` — the double-click path (`FileExplorerPreviewCoordinator.open`),
///   waits for the preview panel of that remote path. With `probe: false` it
///   neither proves the download first nor waits: `{started}`, and a refusal is
///   the coordinator's alert (see `alert`).
/// - `preview {path}` — the open preview panels of that remote path (id and the
///   sha256 of what each shows) and the alert, if one is up.
/// - `alert` — the alert up on the workspace's window (a sheet) or app-modal:
///   `{shown, presentation?, texts?, buttons?}`.
/// - `dismiss_alert` — presses that alert's first button (OK): `{dismissed}`.
/// - `materialize {path}` — the preview download alone, so a failure is a
///   reply, never the coordinator's alert.
/// - `search {query}` — the Find tool's controller with the store's scope.
/// - `local_rows {path}` / `local_git_status {path}` — what THIS Mac's own
///   Files panel shows for a folder (the loopback's files are on this disk too).
/// - `menu {path?}` — the file-operation items the panel's context menu offers
///   for the row at `path` (or the empty area), as their action selectors.
/// - `operation {op, path, name?}` — what a confirmed New File / New Folder /
///   Rename / Duplicate / Move to Trash runs for a device folder (`op`:
///   `new_file`, `new_folder`, `rename`, `duplicate`, `trash`), then the
///   panel's refresh; `{ok, path?}` or `{ok: false, error}`.
/// - `menu_action {path, item}` — picks a context-menu item (its action
///   selector, e.g. `supermuxDuplicate:`) for the row at `path` through the
///   panel's own coordinator, as a click does, but for a panel with no window
///   (the Files panel hidden while the operation runs): `{started}`. A
///   failure is the coordinator's alert (see `alert`).
/// - `unmount` — drops the driver's store (its observation and refresh go with it).
@MainActor
enum SupermuxMirrorFilesSocket {
    #if DEBUG
    /// The driver's stores, one per workspace (a window's panel keeps one store).
    private static var stores: [UUID: FileExplorerStore] = [:]
    /// The refresh counters of each driver store (`counters`).
    private static var probes: [UUID: RefreshProbe] = [:]
    /// The windowless coordinator `menu_action` ran an item on, kept until the
    /// next one so its operation's task can report back.
    private static var menuCoordinator: FileExplorerPanelView.Coordinator?
    #endif

    static func handle(_ params: [String: Any], workspace: Workspace) async throws -> [String: Any] {
        #if DEBUG
        let timeout = timeoutDuration(params)
        switch params["action"] as? String ?? "state" {
        case "state":
            let store = mount(workspace)
            await settle(store, timeout: .seconds(min(5, timeout.components.seconds)))
            return describe(store, workspace: workspace)
        case "counters":
            let key = ObjectIdentifier(mount(workspace))
            guard let probe = probes[workspace.id] else { return [:] }
            var counts = probe.snapshot()
            counts["refreshes"] = SupermuxMirrorFileExplorerLiveRefresh.refreshRuns[key] ?? 0
            if params["reset"] as? Bool == true {
                probe.reset()
                SupermuxMirrorFileExplorerLiveRefresh.refreshRuns[key] = nil
            }
            return counts
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
        case "preview":
            let path = try SupermuxMirrorSocketCommands.string(params, "path")
            return ["panels": previewPanels(workspace, remotePath: path).map { describe($0) }, "alert": alert(workspace)]
        case "alert":
            return alert(workspace)
        case "dismiss_alert":
            return ["dismissed": dismissAlert(workspace)]
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
        case "menu":
            let store = mount(workspace)
            await settle(store, timeout: timeout)
            return ["items": menuItems(params["path"] as? String, store: store)]
        case "operation":
            let store = mount(workspace)
            await settle(store, timeout: timeout)
            return await operation(params, store: store)
        case "menu_action":
            let store = mount(workspace)
            await settle(store, timeout: timeout)
            return try menuAction(params, store: store)
        case "unmount":
            stores[workspace.id]?.applyWorkspaceRoot(.none)
            probes[workspace.id] = nil
            if let store = stores[workspace.id] {
                SupermuxMirrorFileExplorerLiveRefresh.refreshRuns[ObjectIdentifier(store)] = nil
            }
            return ["unmounted": stores.removeValue(forKey: workspace.id) != nil]
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(
                message: "action must be state, counters, expand, open, preview, alert, dismiss_alert, materialize, search, local_rows, local_git_status, menu, operation, menu_action or unmount"
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
        if stores[workspace.id] == nil { probes[workspace.id] = RefreshProbe(store) }
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
            "expanded_paths": store.expandedPaths.sorted(),
            "selected_path": store.selectedPath ?? NSNull(),
        ]
    }

    /// Counts the panel's visible refreshes from the store's own published
    /// values: what `reload()` does (rows emptied, the spinner shown) against
    /// a refresh in place (rows rebuilt, git colors published).
    private final class RefreshProbe {
        private var emptied = 0
        private var loadingShown = 0
        private var rebuilt = 0
        private var gitPublished = 0
        private var since = Date()
        private var subscriptions: Set<AnyCancellable> = []

        @MainActor
        init(_ store: FileExplorerStore) {
            store.$rootNodes.map(\.isEmpty).removeDuplicates().dropFirst().filter { $0 }
                .sink { [weak self] _ in self?.emptied += 1 }.store(in: &subscriptions)
            store.$isRootLoading.removeDuplicates().dropFirst().filter { $0 }
                .sink { [weak self] _ in self?.loadingShown += 1 }.store(in: &subscriptions)
            store.$contentRevision.removeDuplicates().dropFirst()
                .sink { [weak self] _ in self?.rebuilt += 1 }.store(in: &subscriptions)
            store.$gitStatusByPath.dropFirst()
                .sink { [weak self] _ in self?.gitPublished += 1 }.store(in: &subscriptions)
        }

        func snapshot() -> [String: Any] {
            [
                "emptied": emptied, "loading_shown": loadingShown, "rebuilt": rebuilt,
                "git_published": gitPublished, "since_seconds": Date().timeIntervalSince(since),
            ]
        }

        func reset() {
            emptied = 0; loadingShown = 0; rebuilt = 0; gitPublished = 0
            since = Date()
        }
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
        guard let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "the workspace has no pane")
        }
        guard params["probe"] as? Bool ?? true else {
            FileExplorerPreviewCoordinator(store: store).open(path: path, workspace: workspace, pane: pane, isCurrent: { true })
            return ["started": true]
        }
        // A failed download is the coordinator's alert: prove the download
        // works first, so this reply says why instead.
        let probe = await materialize(path, store: store)
        guard probe["ok"] as? Bool == true else { return ["opened": false, "probe": probe] }
        FileExplorerPreviewCoordinator(store: store).open(path: path, workspace: workspace, pane: pane, isCurrent: { true })
        var panel: FilePreviewPanel?
        try await waitUntil(timeout) {
            panel = previewPanels(workspace, remotePath: path).first
            return panel != nil
        }
        guard let panel else { return ["opened": false] }
        return describe(panel).merging([
            "opened": true,
            "read_only": panel.cloudPreviewLease != nil,
            "provider_identity": panel.cloudPreviewProviderIdentity ?? NSNull(),
            "panel_count": previewPanels(workspace, remotePath: path).count,
            "focused_panel_id": workspace.focusedPanelId?.uuidString ?? NSNull(),
        ]) { _, new in new }
    }

    private static func previewPanels(_ workspace: Workspace, remotePath: String) -> [FilePreviewPanel] {
        workspace.panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .filter { !$0.isClosed && $0.cloudPreviewRemotePath == remotePath }
    }

    /// A preview panel's id and the sha256 of the copy it shows.
    private static func describe(_ panel: FilePreviewPanel) -> [String: Any] {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: panel.filePath))) ?? Data()
        return ["panel_id": panel.id.uuidString, "sha256": sha256(data)]
    }

    // MARK: - Alerts

    /// The alert up for the workspace: a sheet on its window, else an
    /// app-modal one.
    private static func alertWindow(_ workspace: Workspace) -> (NSWindow, String)? {
        let host = AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id)
            ?? NSApp.cmuxMainWindowForModalPresentation()
        if let sheet = host?.attachedSheet { return (sheet, "sheet") }
        if let modal = NSApp.modalWindow { return (modal, "app_modal") }
        return nil
    }

    private static func alert(_ workspace: Workspace) -> [String: Any] {
        guard let (window, presentation) = alertWindow(workspace), let content = window.contentView else {
            return ["shown": false]
        }
        let views = visibleSubviews(of: content)
        let texts = views.compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }
        return [
            "shown": true,
            "presentation": presentation,
            "texts": texts.filter { !$0.isEmpty },
            "buttons": buttons(in: content).map(\.title),
        ]
    }

    /// Presses the alert's default button (OK), else its first one.
    private static func dismissAlert(_ workspace: Workspace) -> Bool {
        guard let content = alertWindow(workspace)?.0.contentView else { return false }
        let buttons = buttons(in: content)
        guard let button = buttons.first(where: { $0.keyEquivalent == "\r" }) ?? buttons.first else { return false }
        button.performClick(nil)
        return true
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        visibleSubviews(of: view).compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
    }

    private static func visibleSubviews(of view: NSView) -> [NSView] {
        var found: [NSView] = []
        for child in view.subviews where !child.isHidden {
            found.append(child)
            found += visibleSubviews(of: child)
        }
        return found
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

    // MARK: - File operations

    /// The panel's file-operation menu items for a row (or the empty area),
    /// built by the same code the context menu runs.
    private static func menuItems(_ path: String?, store: FileExplorerStore) -> [String] {
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let menu = NSMenu()
        if let path, let node = findNode(path, in: store.rootNodes) {
            menu.addSupermuxFileOperationItems(coordinator: coordinator, clickedNode: node)
        } else {
            menu.addSupermuxRootFileOperationItems(coordinator: coordinator)
        }
        return menu.items.filter { !$0.isSeparatorItem }.compactMap { $0.action.map(NSStringFromSelector) }
    }

    /// Picks the row's context-menu item with action `item` on a coordinator
    /// with no window, as a hidden Files panel's would run it.
    private static func menuAction(_ params: [String: Any], store: FileExplorerStore) throws -> [String: Any] {
        let path = try SupermuxMirrorSocketCommands.string(params, "path")
        let item = try SupermuxMirrorSocketCommands.string(params, "item")
        guard let node = findNode(path, in: store.rootNodes) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "no loaded row at \(path)")
        }
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let menu = NSMenu()
        menu.addSupermuxFileOperationItems(coordinator: coordinator, clickedNode: node)
        guard let menuItem = menu.items.first(where: { $0.action.map(NSStringFromSelector) == item }),
              let action = menuItem.action else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "the row's menu has no \(item)")
        }
        menuCoordinator = coordinator
        let started = NSApp.sendAction(action, to: menuItem.target, from: menuItem)
        return ["started": started, "has_window": coordinator.supermuxHostWindow != nil]
    }

    /// Runs one operation through the panel's remote provider, then refreshes
    /// the panel the way a confirmed menu operation does.
    private static func operation(_ params: [String: Any], store: FileExplorerStore) async -> [String: Any] {
        guard let provider = store.provider as? SupermuxDeviceFileExplorerProvider,
              let path = params["path"] as? String else {
            return ["ok": false, "error": "the panel is not on a device folder"]
        }
        let name = params["name"] as? String ?? ""
        var result: [String: Any]
        do {
            let changed: String?
            switch params["op"] as? String ?? "" {
            case "new_file": changed = try await provider.create(at: path, folder: false)
            case "new_folder": changed = try await provider.create(at: path, folder: true)
            case "rename": changed = try await provider.rename(path, to: name)
            case "duplicate": changed = try await provider.duplicate(path)
            case "trash":
                try await provider.trash([path])
                changed = nil
            default: return ["ok": false, "error": "op must be new_file, new_folder, rename, duplicate or trash"]
            }
            result = ["ok": true, "path": changed ?? NSNull()]
        } catch {
            result = ["ok": false, "error": error.localizedDescription]
        }
        store.reload()
        store.refreshGitStatus()
        return result
    }

    private static func timeoutDuration(_ params: [String: Any]) -> Duration {
        let seconds = min(max((params["timeout_seconds"] as? NSNumber)?.doubleValue ?? 20, 1), 120)
        return .milliseconds(Int(seconds * 1000))
    }
    #endif
}

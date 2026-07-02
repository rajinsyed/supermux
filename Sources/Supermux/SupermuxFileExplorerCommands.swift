import AppKit
import SupermuxKit

/// How long a pending post-file-op reveal stays eligible. Generous enough for
/// the legitimate multi-reload case (the parent folder's async child load), yet
/// bounded so an orphaned reveal cannot linger for the whole session.
private let supermuxRevealTimeout: TimeInterval = 10

// MARK: - Context-menu population

extension NSMenu {
    /// Appends the supermux file-operation items for a clicked tree node:
    /// New File / New Folder (scoped to the node's directory), Rename, Duplicate,
    /// and Move to Trash. No-op for non-local providers (SSH file ops unsupported).
    func addSupermuxFileOperationItems(
        coordinator: FileExplorerPanelView.Coordinator,
        clickedNode node: FileExplorerNode
    ) {
        guard coordinator.store.provider is LocalFileExplorerProvider else { return }

        let parentDirectory: URL
        let expandNode: FileExplorerNode?
        if node.isDirectory {
            parentDirectory = URL(fileURLWithPath: node.path)
            expandNode = node
        } else {
            parentDirectory = URL(fileURLWithPath: node.path).deletingLastPathComponent()
            expandNode = nil
        }
        let request = SupermuxFileOpRequest(parentDirectory: parentDirectory, expandNode: expandNode)

        addItem(.separator())
        addSupermuxItem(SupermuxFileOpText.newFileMenu, #selector(FileExplorerPanelView.Coordinator.supermuxNewFile(_:)), coordinator, request)
        addSupermuxItem(SupermuxFileOpText.newFolderMenu, #selector(FileExplorerPanelView.Coordinator.supermuxNewFolder(_:)), coordinator, request)
        addItem(.separator())
        addSupermuxItem(SupermuxFileOpText.renameMenu, #selector(FileExplorerPanelView.Coordinator.supermuxRename(_:)), coordinator, node)
        addSupermuxItem(SupermuxFileOpText.duplicateMenu, #selector(FileExplorerPanelView.Coordinator.supermuxDuplicate(_:)), coordinator, node)
        addSupermuxItem(SupermuxFileOpText.moveToTrashMenu, #selector(FileExplorerPanelView.Coordinator.supermuxMoveToTrash(_:)), coordinator, node)
    }

    /// Appends only New File / New Folder, scoped to the explorer root. Used when
    /// the user right-clicks the empty area below the tree (no node clicked).
    func addSupermuxRootFileOperationItems(coordinator: FileExplorerPanelView.Coordinator) {
        guard coordinator.store.provider is LocalFileExplorerProvider,
              !coordinator.store.rootPath.isEmpty else { return }
        let request = SupermuxFileOpRequest(
            parentDirectory: URL(fileURLWithPath: coordinator.store.rootPath),
            expandNode: nil
        )
        addSupermuxItem(SupermuxFileOpText.newFileMenu, #selector(FileExplorerPanelView.Coordinator.supermuxNewFile(_:)), coordinator, request)
        addSupermuxItem(SupermuxFileOpText.newFolderMenu, #selector(FileExplorerPanelView.Coordinator.supermuxNewFolder(_:)), coordinator, request)
    }

    private func addSupermuxItem(_ title: String, _ action: Selector, _ target: AnyObject, _ representedObject: Any) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = representedObject
        addItem(item)
    }
}

// MARK: - Shared command handlers

@MainActor
extension FileExplorerPanelView.Coordinator {
    @objc func supermuxNewFile(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SupermuxFileOpRequest else { return }
        supermuxPromptAndCreate(
            title: SupermuxFileOpText.newFileTitle,
            messageFormat: SupermuxFileOpText.newFileMessageFormat,
            request: request
        ) { name, directory in
            try SupermuxFileSystemOperations.createFile(named: name, in: directory)
        }
    }

    @objc func supermuxNewFolder(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SupermuxFileOpRequest else { return }
        supermuxPromptAndCreate(
            title: SupermuxFileOpText.newFolderTitle,
            messageFormat: SupermuxFileOpText.newFolderMessageFormat,
            request: request
        ) { name, directory in
            try SupermuxFileSystemOperations.createDirectory(named: name, in: directory)
        }
    }

    /// Shared New File / New Folder flow: prompt for a name, then create the
    /// item through `supermuxRunFileOperation` — off the main actor, like
    /// duplicate/trash, because even an empty-file write can block for seconds
    /// on a stalled network volume. On success the request's directory node is
    /// expanded (main actor, via `onApply`) and the new item revealed; on
    /// failure the error is surfaced and the tree still refreshes.
    private func supermuxPromptAndCreate(
        title: String,
        messageFormat: String,
        request: SupermuxFileOpRequest,
        make: @escaping @Sendable (String, URL) throws -> URL
    ) {
        let identity = store.workspaceRootIdentity
        let rootPath = store.rootPath
        supermuxPromptForName(
            title: title,
            message: String(format: messageFormat, request.parentDirectory.lastPathComponent),
            defaultValue: "",
            confirmTitle: SupermuxFileOpText.createButton
        ) { [weak self] name in
            guard let self else { return }
            let showHiddenFiles = self.store.showHiddenFiles
            let parentDirectory = request.parentDirectory
            let expandNode = request.expandNode
            self.supermuxRunFileOperation(
                identity: identity,
                rootPath: rootPath,
                mutatedParentPaths: [parentDirectory.path],
                onApply: { [weak self] in
                    if let expandNode { self?.store.expand(node: expandNode) }
                }
            ) {
                let created = try make(name, parentDirectory)
                return SupermuxFileExplorerSelection.revealForCreatedItem(
                    path: created.path, showHiddenFiles: showHiddenFiles)
            }
        }
    }

    /// Whether the (window-lifetime, reused) store still shows the workspace and
    /// root that an async op was dispatched for. The file explorer can re-root the
    /// SAME workspace (e.g. the terminal cd's), so identity alone is insufficient.
    private func supermuxStoreStillCurrent(identity: UUID?, rootPath: String) -> Bool {
        store.workspaceRootIdentity == identity && store.rootPath == rootPath
    }

    @objc func supermuxRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        supermuxBeginRename(node)
    }

    @objc func supermuxDuplicate(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        // Honor the active multi-selection, like Move to Trash, so Duplicate is
        // not silently partial. Each item is duplicated independently (Finder
        // duplicates a selected folder and a selected child separately).
        let urls = supermuxContextNodes(clicked: node).map { URL(fileURLWithPath: $0.path) }
        supermuxRunFileOperation(
            identity: store.workspaceRootIdentity,
            rootPath: store.rootPath,
            mutatedParentPaths: urls.map { $0.deletingLastPathComponent().path }
        ) {
            var reveal: SupermuxFileExplorerSelection.FileOpReveal = .none
            for url in urls { reveal = .reveal(try SupermuxFileSystemOperations.duplicate(url).path) }
            return reveal
        }
    }

    @objc func supermuxMoveToTrash(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        supermuxMoveNodesToTrash(supermuxContextNodes(clicked: node))
    }

    /// Shared rename entrypoint used by both the context menu and the keyboard.
    /// The move itself runs off the main actor via `supermuxRunFileOperation`
    /// (a `moveItem` on a stalled network volume can block for seconds),
    /// mirroring create/duplicate/trash.
    func supermuxBeginRename(_ node: FileExplorerNode) {
        let identity = store.workspaceRootIdentity
        let rootPath = store.rootPath
        supermuxPromptForName(
            title: SupermuxFileOpText.renameTitle,
            message: String(format: SupermuxFileOpText.renameMessageFormat, node.name),
            defaultValue: node.name,
            confirmTitle: SupermuxFileOpText.renameTitle,
            selectsBaseName: true
        ) { [weak self] name in
            guard let self else { return }
            // Confirming the pre-filled name unchanged is a true no-op (don't let
            // name validation's whitespace-trim silently retarget a padded name).
            guard name != node.name else { return }
            let showHiddenFiles = self.store.showHiddenFiles
            let source = URL(fileURLWithPath: node.path)
            self.supermuxRunFileOperation(
                identity: identity,
                rootPath: rootPath,
                mutatedParentPaths: [source.deletingLastPathComponent().path]
            ) {
                let renamed = try SupermuxFileSystemOperations.rename(source, to: name)
                return SupermuxFileExplorerSelection.revealForRenamedItem(
                    path: renamed.path, showHiddenFiles: showHiddenFiles)
            }
        }
    }

    /// Shared trash entrypoint used by both the context menu and the keyboard.
    func supermuxMoveNodesToTrash(_ nodes: [FileExplorerNode]) {
        let targets = supermuxTopLevelNodes(nodes)
        guard !targets.isEmpty else { return }
        let urls = targets.map { URL(fileURLWithPath: $0.path) }
        // After trashing, retarget the selection to a surviving parent so the
        // authoritative store selection no longer points at a deleted path — which
        // would otherwise dead-end the next ⌘⌫/Return. Skip when the parent is the
        // explorer root (no row to select; selection simply clears on reload).
        let firstParent = urls.first?.deletingLastPathComponent().path
        let revealAfter = SupermuxFileExplorerSelection.revealAfterTrash(
            firstParentPath: firstParent, rootPath: store.rootPath)
        // Capture the staleness scope BEFORE the confirmation sheet (the explorer
        // could re-root while it is open), matching create/rename.
        let identity = store.workspaceRootIdentity
        let rootPath = store.rootPath
        supermuxConfirmTrash(targets) { [weak self] in
            self?.supermuxRunFileOperation(
                identity: identity,
                rootPath: rootPath,
                mutatedParentPaths: urls.map { $0.deletingLastPathComponent().path }
            ) {
                try SupermuxFileSystemOperations.moveToTrash(urls)
                return revealAfter
            }
        }
    }

    /// Runs a filesystem mutation off the main actor (so file I/O on a stalled
    /// volume, duplicating a large folder, or trashing many items never blocks
    /// the UI), then reconciles the (window-lifetime, reused) store against a
    /// possible mid-op workspace/root switch. `identity`/`rootPath` are captured
    /// by the caller BEFORE any confirmation sheet, so the staleness check
    /// reflects the workspace the user actually acted in. On success `onApply`
    /// runs on the main actor (e.g. expanding the destination folder) before the
    /// reveal `work` returns is applied, and the refresh may be skipped when the
    /// root watcher covers every mutated parent; a failure surfaces the error
    /// and always refreshes (which directories actually mutated is unknown).
    private func supermuxRunFileOperation(
        identity: UUID?,
        rootPath: String,
        mutatedParentPaths: [String],
        onApply: (() -> Void)? = nil,
        _ work: @escaping @Sendable () throws -> SupermuxFileExplorerSelection.FileOpReveal
    ) {
        Task { [weak self] in
            let result: Result<SupermuxFileExplorerSelection.FileOpReveal, any Error>
            do {
                result = .success(try await Task.detached(priority: .userInitiated) { try work() }.value)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            let reveal: SupermuxFileExplorerSelection.FileOpReveal
            let failure: (any Error)?
            switch result {
            case .success(let value): reveal = value; failure = nil
            case .failure(let error): reveal = .none; failure = error
            }
            let action = SupermuxFileExplorerSelection.fileOpAction(
                isStale: !self.supermuxStoreStillCurrent(identity: identity, rootPath: rootPath),
                didFail: failure != nil,
                reveal: reveal)
            switch action {
            case .ignore:
                return
            case .apply(let reveal):
                onApply?()
                switch reveal {
                case .none: break
                case .reveal(let path): self.store.supermuxReveal(path: path)
                case .clearSelection: self.store.supermuxClearSelection()
                }
                self.supermuxRefreshAfterFileOperation(mutatedParentPaths: mutatedParentPaths)
            case .presentError:
                if let failure { self.supermuxPresentFileOpError(failure) }
                self.supermuxRefreshAfterFileOperation()
            }
        }
    }

    /// Re-reads the tree and git status after a mutation. The local directory
    /// watcher only observes the root (non-recursive), so subdirectory edits need
    /// an explicit reload to appear. Used directly on failure paths, where the
    /// set of actually-mutated directories is unknown.
    func supermuxRefreshAfterFileOperation() {
        store.reload()
        store.refreshGitStatus()
    }

    /// Post-success refresh, skipped when the root directory watcher already
    /// covers every mutated parent (root-level create/rename/duplicate/trash):
    /// the watcher fires for the same mutation and runs the identical
    /// `reload()` + `refreshGitStatus()` after its 300ms throttle, so refreshing
    /// here too would double a full tree relist and a `git status` spawn per op.
    private func supermuxRefreshAfterFileOperation(mutatedParentPaths: [String]) {
        if SupermuxFileExplorerSelection.explicitRefreshIsRedundant(
            mutatedParentPaths: mutatedParentPaths,
            rootPath: store.rootPath,
            rootIsWatched: store.provider is LocalFileExplorerProvider
        ) { return }
        supermuxRefreshAfterFileOperation()
    }

    // MARK: - Keyboard

    /// Handles ⌘⌫ (Move to Trash) and Return (Rename) while the outline view is
    /// first responder. Returns `true` when the event was consumed.
    func handleSupermuxFileOperationKey(_ event: NSEvent, in outlineView: NSOutlineView) -> Bool {
        guard store.provider is LocalFileExplorerProvider else { return false }
        // Check only the command/control/option modifiers, matching
        // RightSidebarKeyboardNavigation's plain-key convention. This ignores
        // .numericPad (set on keypad Enter, keyCode 76), .shift, and capsLock —
        // otherwise keypad Enter would never reach the rename path.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        let claimsTrash = event.keyCode == 51 && modifiers == [.command]
        let claimsRename = (event.keyCode == 36 || event.keyCode == 76) && modifiers.isEmpty
        guard claimsTrash || claimsRename else { return false }

        // Return-to-rename deliberately shadows Open Selection's BUILT-IN plain-
        // Return default (touchpoint #46; ⌘↓ still opens). But when the user has
        // EXPLICITLY rebound Open Selection onto the pressed keystroke, that
        // choice must win — otherwise the configured binding would be dead UI
        // with no way to restore Return-to-open.
        if supermuxUserConfiguredOpenSelectionMatches(event) { return false }

        if claimsTrash {
            let nodes = supermuxSelectedNodes(in: outlineView)
            guard !nodes.isEmpty else { return false }
            supermuxMoveNodesToTrash(nodes)
            return true
        }
        guard let node = supermuxAnchorNode(in: outlineView) else { return false }
        supermuxBeginRename(node)
        return true
    }

    /// Whether the user explicitly configured Open Selection (or its Finder
    /// alias) to a shortcut matching `event`. Riding the built-in default does
    /// not count — only a cmux.json `shortcuts` entry or a Settings-UI override
    /// expresses intent to reclaim the keystroke from rename/trash.
    private func supermuxUserConfiguredOpenSelectionMatches(_ event: NSEvent) -> Bool {
        let openSelectionActions: [KeyboardShortcutSettings.Action] = [
            .fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias,
        ]
        return openSelectionActions.contains { action in
            let isUserConfigured = KeyboardShortcutSettings.isManagedBySettingsFile(action)
                || UserDefaults.standard.data(forKey: action.defaultsKey) != nil
            return isUserConfigured && KeyboardShortcutSettings.shortcut(for: action).matches(event: event)
        }
    }

    // MARK: - Node resolution

    /// Destructive keyboard targets, resolved from the *authoritative* store
    /// selection (not the raw visual selection). During a reveal into a
    /// not-yet-loaded subtree the visual selection can transiently sit on a
    /// parent folder while `store.selectedPaths` already holds the new item — so
    /// trusting the visual selection could ⌘⌫-trash the wrong (parent) folder.
    private func supermuxSelectedNodes(in outlineView: NSOutlineView) -> [FileExplorerNode] {
        let visible = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
        let keep = Set(SupermuxFileExplorerSelection.authoritativePaths(
            visible: visible.map(\.path), authoritative: store.selectedPaths))
        return visible.filter { keep.contains($0.path) }
    }

    private func supermuxAnchorNode(in outlineView: NSOutlineView) -> FileExplorerNode? {
        // Resolve the rename anchor from the authoritative store path, not the
        // transient visual row (same reveal-gap divergence as above).
        guard let anchorPath = store.selectedPath else { return nil }
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileExplorerNode, node.path == anchorPath {
                return node
            }
        }
        return nil
    }

    /// Drops nodes that are descendants of another node in the same set, so
    /// trashing a folder does not then fail on its already-trashed children.
    /// Delegates to the pure, unit-tested `SupermuxFileSystemOperations.topLevelPaths`.
    private func supermuxTopLevelNodes(_ nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        let keep = Set(SupermuxFileSystemOperations.topLevelPaths(nodes.map(\.path)))
        return nodes.filter { keep.contains($0.path) }
    }

    /// Scrolls the row for `path` into view if it is present, returning whether it
    /// was found. The selection itself is applied by the store's `applyStoredSelection`
    /// (selectedPath == path); this only handles the scroll. Called from
    /// `reloadIfNeeded` so a just-created/renamed item is revealed once its row loads.
    /// A reveal whose row never materializes (parent collapsed mid-load, item
    /// filtered out) expires after `supermuxRevealTimeout` — without a deadline
    /// the flag would dangle across unrelated reloads and yank the viewport
    /// whenever the row eventually appears, minutes later.
    func supermuxRevealRowIfPresent(_ path: String, in outlineView: NSOutlineView) -> Bool {
        if let requestedAt = store.supermuxRevealRequestedAt,
           Date().timeIntervalSince(requestedAt) > supermuxRevealTimeout {
            store.supermuxRevealPath = nil
            return false
        }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
            if node.path == path {
                outlineView.scrollRowToVisible(row)
                return true
            }
        }
        return false
    }

    /// Resolves which nodes a node-targeted context action applies to: the whole
    /// selection when the clicked row is part of it, otherwise just the clicked node.
    private func supermuxContextNodes(clicked node: FileExplorerNode) -> [FileExplorerNode] {
        guard let outlineView else { return [node] }
        let clickedRow = outlineView.clickedRow
        let clickedRowIsSelected = clickedRow >= 0 && outlineView.selectedRowIndexes.contains(clickedRow)
        let selectedNodes = outlineView.selectedRowIndexes.compactMap { row -> FileExplorerNode? in
            guard row >= 0, row < outlineView.numberOfRows else { return nil }
            return outlineView.item(atRow: row) as? FileExplorerNode
        }
        let targets = Set(SupermuxFileExplorerSelection.contextTargetPaths(
            clickedPath: node.path,
            clickedRowIsSelected: clickedRowIsSelected,
            selectedPaths: selectedNodes.map(\.path)))
        let resolved = selectedNodes.filter { targets.contains($0.path) }
        return resolved.isEmpty ? [node] : resolved
    }
}

import AppKit
import SupermuxKit

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
        let identity = store.workspaceRootIdentity
        supermuxPromptForName(
            title: SupermuxFileOpText.newFileTitle,
            message: String(format: SupermuxFileOpText.newFileMessageFormat, request.parentDirectory.lastPathComponent),
            defaultValue: "",
            confirmTitle: SupermuxFileOpText.createButton
        ) { [weak self] name in
            guard let self else { return }
            do {
                let created = try SupermuxFileSystemOperations.createFile(named: name, in: request.parentDirectory)
                guard self.store.workspaceRootIdentity == identity else { return }
                if let node = request.expandNode { self.store.expand(node: node) }
                self.store.supermuxReveal(path: created.path)
                self.supermuxRefreshAfterFileOperation()
            } catch {
                guard self.store.workspaceRootIdentity == identity else { return }
                self.supermuxPresentFileOpError(error)
            }
        }
    }

    @objc func supermuxNewFolder(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SupermuxFileOpRequest else { return }
        let identity = store.workspaceRootIdentity
        supermuxPromptForName(
            title: SupermuxFileOpText.newFolderTitle,
            message: String(format: SupermuxFileOpText.newFolderMessageFormat, request.parentDirectory.lastPathComponent),
            defaultValue: "",
            confirmTitle: SupermuxFileOpText.createButton
        ) { [weak self] name in
            guard let self else { return }
            do {
                let created = try SupermuxFileSystemOperations.createDirectory(named: name, in: request.parentDirectory)
                guard self.store.workspaceRootIdentity == identity else { return }
                if let node = request.expandNode { self.store.expand(node: node) }
                self.store.supermuxReveal(path: created.path)
                self.supermuxRefreshAfterFileOperation()
            } catch {
                guard self.store.workspaceRootIdentity == identity else { return }
                self.supermuxPresentFileOpError(error)
            }
        }
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
        supermuxRunFileOperation {
            var lastCopy: String?
            for url in urls { lastCopy = try SupermuxFileSystemOperations.duplicate(url).path }
            return lastCopy
        }
    }

    @objc func supermuxMoveToTrash(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        supermuxMoveNodesToTrash(supermuxContextNodes(clicked: node))
    }

    /// Shared rename entrypoint used by both the context menu and the keyboard.
    func supermuxBeginRename(_ node: FileExplorerNode) {
        let identity = store.workspaceRootIdentity
        supermuxPromptForName(
            title: SupermuxFileOpText.renameTitle,
            message: String(format: SupermuxFileOpText.renameMessageFormat, node.name),
            defaultValue: node.name,
            confirmTitle: SupermuxFileOpText.renameTitle
        ) { [weak self] name in
            guard let self else { return }
            do {
                let renamed = try SupermuxFileSystemOperations.rename(URL(fileURLWithPath: node.path), to: name)
                guard self.store.workspaceRootIdentity == identity else { return }
                self.store.supermuxReveal(path: renamed.path)
                self.supermuxRefreshAfterFileOperation()
            } catch {
                guard self.store.workspaceRootIdentity == identity else { return }
                self.supermuxPresentFileOpError(error)
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
        let revealAfter = (firstParent != nil && firstParent != store.rootPath) ? firstParent : nil
        supermuxConfirmTrash(targets) { [weak self] in
            self?.supermuxRunFileOperation {
                try SupermuxFileSystemOperations.moveToTrash(urls)
                return revealAfter
            }
        }
    }

    /// Runs a filesystem mutation off the main actor (so duplicating a large
    /// folder or trashing many items never blocks the UI), then always refreshes
    /// the tree — including after a partial failure — surfaces any error, and
    /// reveals the path `work` returns (a newly created item), if any.
    private func supermuxRunFileOperation(_ work: @escaping @Sendable () throws -> String?) {
        // Capture the workspace the op belongs to. The store is reused across
        // workspace switches in the window, so if the user switches before the
        // detached work finishes we must NOT reveal/refresh this (now-foreign)
        // store with the old workspace's path.
        let identity = store.workspaceRootIdentity
        Task { [weak self] in
            let result: Result<String?, any Error>
            do {
                result = .success(try await Task.detached(priority: .userInitiated) { try work() }.value)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            let revealPath: String?
            let failure: (any Error)?
            switch result {
            case .success(let path): revealPath = path; failure = nil
            case .failure(let error): revealPath = nil; failure = error
            }
            let action = SupermuxFileExplorerSelection.fileOpAction(
                isStale: self.store.workspaceRootIdentity != identity,
                didFail: failure != nil,
                revealPath: revealPath)
            switch action {
            case .ignore:
                return
            case .reveal(let path):
                if let path { self.store.supermuxReveal(path: path) }
            case .presentError:
                if let failure { self.supermuxPresentFileOpError(failure) }
            }
            if action.refreshesTree { self.supermuxRefreshAfterFileOperation() }
        }
    }

    /// Re-reads the tree and git status after a mutation. The local directory
    /// watcher only observes the root (non-recursive), so subdirectory edits need
    /// an explicit reload to appear.
    func supermuxRefreshAfterFileOperation() {
        store.reload()
        store.refreshGitStatus()
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

        if event.keyCode == 51, modifiers == [.command] {
            let nodes = supermuxSelectedNodes(in: outlineView)
            guard !nodes.isEmpty else { return false }
            supermuxMoveNodesToTrash(nodes)
            return true
        }

        if event.keyCode == 36 || event.keyCode == 76, modifiers.isEmpty {
            guard let node = supermuxAnchorNode(in: outlineView) else { return false }
            supermuxBeginRename(node)
            return true
        }

        return false
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
    func supermuxRevealRowIfPresent(_ path: String, in outlineView: NSOutlineView) -> Bool {
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

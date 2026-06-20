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
        supermuxPromptForName(
            title: SupermuxFileOpText.newFileTitle,
            message: String(format: SupermuxFileOpText.newFileMessageFormat, request.parentDirectory.lastPathComponent),
            defaultValue: "",
            confirmTitle: SupermuxFileOpText.createButton
        ) { [weak self] name in
            guard let self else { return }
            do {
                try SupermuxFileSystemOperations.createFile(named: name, in: request.parentDirectory)
                if let node = request.expandNode { self.store.expand(node: node) }
                self.supermuxRefreshAfterFileOperation()
            } catch {
                self.supermuxPresentFileOpError(error)
            }
        }
    }

    @objc func supermuxNewFolder(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SupermuxFileOpRequest else { return }
        supermuxPromptForName(
            title: SupermuxFileOpText.newFolderTitle,
            message: String(format: SupermuxFileOpText.newFolderMessageFormat, request.parentDirectory.lastPathComponent),
            defaultValue: "",
            confirmTitle: SupermuxFileOpText.createButton
        ) { [weak self] name in
            guard let self else { return }
            do {
                try SupermuxFileSystemOperations.createDirectory(named: name, in: request.parentDirectory)
                if let node = request.expandNode { self.store.expand(node: node) }
                self.supermuxRefreshAfterFileOperation()
            } catch {
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
        let url = URL(fileURLWithPath: node.path)
        supermuxRunFileOperation { _ = try SupermuxFileSystemOperations.duplicate(url) }
    }

    @objc func supermuxMoveToTrash(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        supermuxMoveNodesToTrash(supermuxContextNodes(clicked: node))
    }

    /// Shared rename entrypoint used by both the context menu and the keyboard.
    func supermuxBeginRename(_ node: FileExplorerNode) {
        supermuxPromptForName(
            title: SupermuxFileOpText.renameTitle,
            message: String(format: SupermuxFileOpText.renameMessageFormat, node.name),
            defaultValue: node.name,
            confirmTitle: SupermuxFileOpText.renameTitle
        ) { [weak self] name in
            guard let self else { return }
            do {
                _ = try SupermuxFileSystemOperations.rename(URL(fileURLWithPath: node.path), to: name)
                self.supermuxRefreshAfterFileOperation()
            } catch {
                self.supermuxPresentFileOpError(error)
            }
        }
    }

    /// Shared trash entrypoint used by both the context menu and the keyboard.
    func supermuxMoveNodesToTrash(_ nodes: [FileExplorerNode]) {
        let targets = supermuxTopLevelNodes(nodes)
        guard !targets.isEmpty else { return }
        let urls = targets.map { URL(fileURLWithPath: $0.path) }
        supermuxConfirmTrash(targets) { [weak self] in
            self?.supermuxRunFileOperation { try SupermuxFileSystemOperations.moveToTrash(urls) }
        }
    }

    /// Runs a filesystem mutation off the main actor (so duplicating a large
    /// folder or trashing many items never blocks the UI), then always refreshes
    /// the tree — including after a partial failure — and surfaces any error.
    private func supermuxRunFileOperation(_ work: @escaping @Sendable () throws -> Void) {
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { try work() }.value
            } catch {
                self?.supermuxPresentFileOpError(error)
            }
            self?.supermuxRefreshAfterFileOperation()
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 51, flags == [.command] {
            let nodes = supermuxSelectedNodes(in: outlineView)
            guard !nodes.isEmpty else { return false }
            supermuxMoveNodesToTrash(nodes)
            return true
        }

        if event.keyCode == 36 || event.keyCode == 76, flags.isEmpty {
            guard let node = supermuxAnchorNode(in: outlineView) else { return false }
            supermuxBeginRename(node)
            return true
        }

        return false
    }

    // MARK: - Node resolution

    private func supermuxSelectedNodes(in outlineView: NSOutlineView) -> [FileExplorerNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
    }

    private func supermuxAnchorNode(in outlineView: NSOutlineView) -> FileExplorerNode? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileExplorerNode
    }

    /// Drops nodes that are descendants of another node in the same set, so
    /// trashing a folder does not then fail on its already-trashed children.
    private func supermuxTopLevelNodes(_ nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        let paths = nodes.map(\.path)
        return nodes.filter { node in
            !paths.contains { $0 != node.path && Self.supermuxPath($0, isAncestorOf: node.path) }
        }
    }

    private static func supermuxPath(_ ancestor: String, isAncestorOf descendant: String) -> Bool {
        guard ancestor != descendant else { return false }
        if ancestor == "/" { return descendant.hasPrefix("/") }
        return descendant.hasPrefix(ancestor + "/")
    }

    /// Resolves which nodes a node-targeted context action applies to: the whole
    /// selection when the clicked row is part of it, otherwise just the clicked node.
    private func supermuxContextNodes(clicked node: FileExplorerNode) -> [FileExplorerNode] {
        guard let outlineView else { return [node] }
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0, outlineView.selectedRowIndexes.contains(clickedRow) else { return [node] }
        let nodes = outlineView.selectedRowIndexes.compactMap { row -> FileExplorerNode? in
            guard row >= 0, row < outlineView.numberOfRows else { return nil }
            return outlineView.item(atRow: row) as? FileExplorerNode
        }
        return nodes.isEmpty ? [node] : nodes
    }
}

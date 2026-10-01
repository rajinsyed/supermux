import Foundation

/// Applies a device mirror's Files root (`FileExplorerWorkspaceRoot.supermuxDevice`,
/// touchpoint `mirror-file-explorer-device`): the owning Mac's folder through
/// ``SupermuxDeviceFileExplorerProvider``, refreshed live from that Mac.
extension FileExplorerStore {
    func applySupermuxDeviceWorkspaceRoot(_ root: SupermuxMirrorFileRoot) {
        setWorkspaceRootIdentity(root.workspaceID)
        cancelRemoteHomeResolution()
        setRootStatusMessage(nil)
        if (provider as? SupermuxDeviceFileExplorerProvider)?.root != root {
            // A new folder (or Mac) is a new provider: nothing listed under
            // the old one may be read through the new one.
            setRootPath("")
            setProvider(SupermuxDeviceFileExplorerProvider(root: root, devices: SupermuxComposition.devices), reloadIfAvailable: false)
        }
        setRootPath(root.rootPath)
        SupermuxMirrorFileExplorerLiveRefresh.start(for: self)
    }

    /// The live refresh of a device mirror's tree, done in place: the root
    /// and every expanded, loaded folder are listed again over the link and
    /// merged into the rows already shown, so the tree never empties or shows
    /// the spinner, expanded folders stay open and the selection stays put.
    /// `reload()` would do all of that visibly while each listing travels.
    ///
    /// Rows are rebuilt only when a listing changed. A folder that is loaded
    /// but collapsed forgets its rows, so opening it lists it fresh (as after
    /// the local panel's reload). A failed listing keeps its rows. Git colors
    /// follow, as with each local watcher event.
    func supermuxRefreshInPlace() async {
        // A first load (or a reload) in flight is upstream's.
        guard let device = provider as? SupermuxDeviceFileExplorerProvider,
              !rootPath.isEmpty, !isRootLoading else { return }
        let revision = contentRevision, context = resourceContextID
        var changed = false
        var pending: [(parent: FileExplorerNode?, path: String)] = [(nil, rootPath)]
        while !pending.isEmpty {
            let (parent, path) = pending.removeFirst()
            guard let entries = try? await device.listDirectory(path: path, showHidden: showHiddenFiles) else { continue }
            // A reload, a re-root or another provider won meanwhile.
            guard contentRevision == revision, resourceContextID == context, provider === device else { return }
            let current = parent?.children ?? rootNodes
            let merged = Self.supermuxMerged(current, with: entries, context: context)
            if merged.count != current.count || zip(merged, current).contains(where: { $0 !== $1 }) {
                changed = true
                if let parent { parent.children = merged } else { rootNodes = merged }
            }
            if parent == nil { setRootStatusMessage(nil) }
            for child in merged where child.isDirectory && child.children != nil {
                if expandedPaths.contains(child.path) {
                    pending.append((child, child.path))
                } else {
                    child.children = nil
                }
            }
        }
        if changed { supermuxNoteTreeChanged() }
        refreshGitStatus()
    }

    /// The listing as nodes, reusing the shown node for every entry that is
    /// still there (same path, same kind) so its children and expansion
    /// survive; new entries get fresh nodes. Upstream's order: folders first,
    /// then by name.
    private static func supermuxMerged(
        _ current: [FileExplorerNode],
        with entries: [FileExplorerEntry],
        context: UUID
    ) -> [FileExplorerNode] {
        let shown = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.map { entry in
            if let node = shown[entry.path], node.isDirectory == entry.isDirectory { return node }
            let node = FileExplorerNode(name: entry.name, path: entry.path, isDirectory: entry.isDirectory)
            node.resourceContextID = context
            return node
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

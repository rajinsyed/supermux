public import Foundation

/// Terminal-presets CRUD and durable directory→project links for
/// ``SupermuxProjectsModel``. Split out of the main model file to keep it
/// within the Swift file-length budget; all writes flow through the model's
/// shared semantic `persist(_:)` chain.
extension SupermuxProjectsModel {
    // MARK: - Terminal presets

    /// Appends a new launchable preset to the bar.
    /// - Parameter preset: The preset to add (kept even if not yet launchable
    ///   so the editor can fill it in).
    public func addPreset(_ preset: SupermuxTerminalPreset) {
        presets.append(preset)
        persist { file in
            var list = file.presets ?? []
            guard !list.contains(where: { $0.id == preset.id }) else { return }
            list.append(preset)
            file.presets = list
        }
    }

    /// Replaces a preset by ``SupermuxTerminalPreset/id``; no-op when unknown.
    /// - Parameter preset: Updated record.
    public func updatePreset(_ preset: SupermuxTerminalPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist { file in
            guard var list = file.presets,
                  let i = list.firstIndex(where: { $0.id == preset.id }) else { return }
            list[i] = preset
            file.presets = list
        }
    }

    /// Removes a preset from the bar.
    /// - Parameter id: Preset to remove.
    public func removePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        persist { file in
            guard var list = file.presets else { return }
            list.removeAll { $0.id == id }
            file.presets = list
        }
    }

    /// Replaces the entire ordered preset list (used by the editor sheet on
    /// save, which owns reordering and field edits in local state). A
    /// wholesale replace on purpose: the editor owns the whole ordered list,
    /// so last-writer-wins across app instances is the intended contract.
    /// - Parameter presets: The new ordered list.
    public func setPresets(_ presets: [SupermuxTerminalPreset]) {
        self.presets = presets
        persist { $0.presets = presets }
    }

    /// Restores the bar to ``SupermuxTerminalPreset/defaults``.
    public func resetPresetsToDefaults() {
        setPresets(SupermuxTerminalPreset.defaults)
    }

    // MARK: - Directory associations (SupermuxDirectoryAssociationPersisting)

    public func associateDirectory(_ directory: String, with projectId: UUID) {
        let key = SupermuxProjectMatcher.normalizedDirectory(directory)
        guard !key.isEmpty else { return }
        // Worktree directories nest structurally (``SupermuxProjectMatcher``
        // matches the worktrees dir), so a durable link for them is redundant —
        // and would linger as a stale entry after the worktree is deleted, since
        // links are only cleared on project removal. Persist only links we need:
        // the project's main/root workspace, which has no structural signal.
        guard worktreeMatcher.projectOwningWorktree(for: key, in: projects) == nil else { return }
        // Also key the symlink-resolved form: live PWD reports can carry the
        // physical path while the project was registered through a symlink, and
        // lookups never resolve symlinks (they run on render paths). Resolution
        // happens here, on the write path, only.
        let keys = Set([key, SupermuxProjectMatcher.resolvedDirectory(key)])
        guard keys.contains(where: { directoryAssociations[$0] != projectId }) else { return }
        for candidate in keys { directoryAssociations[candidate] = projectId }
        persist { file in
            var associations = file.directoryAssociations ?? [:]
            for candidate in keys { associations[candidate] = projectId }
            file.directoryAssociations = associations
        }
    }
}

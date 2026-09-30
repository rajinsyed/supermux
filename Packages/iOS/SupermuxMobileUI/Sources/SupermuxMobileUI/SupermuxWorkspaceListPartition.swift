public import CmuxMobileShellModel
import SupermuxMobileKit

extension [MobileWorkspacePreview] {
    /// The flat-list side of the §6 augmentation: which workspace rows stay
    /// in the shell's flat list once project-associated workspaces fold under
    /// their project (they remain reachable through the project detail's
    /// Workspaces section).
    ///
    /// Mirrors the Mac sidebar's `SupermuxProjectResolutionCache.filter`
    /// semantics: only LOOSE project-owned workspaces hide; a cmux-grouped
    /// workspace stays with its group section even when a project owns it.
    ///
    /// A workspace hides ONLY when its owning project is actually a row in the
    /// section (`shownProjectIDs`) — so it stays reachable by expanding that
    /// project. A project-associated workspace whose project is NOT shown (a
    /// second paired Mac's workspace whose project lives under the other Mac,
    /// or any workspace while `projects.list` has not yet loaded) stays in the
    /// flat list rather than vanishing with no way to reach it.
    ///
    /// Keyed by (Mac, project): the shown ids are the section's ROW ids
    /// (``SupermuxProjectKey/rawValue``), so a workspace folds only under its
    /// OWN Mac's project, even if another Mac reuses the project id. A bare
    /// project id (single legacy session) still matches by project alone.
    ///
    /// - Parameter shownProjectIDs: The project row ids currently rendered in
    ///   the Projects section. Empty disables folding entirely (the shell
    ///   passes empty while the section is hidden, unloaded, or
    ///   searching/filtering), so no workspace ever becomes unreachable or
    ///   unsearchable.
    /// - Returns: The rows minus the ungrouped workspaces owned by a shown
    ///   project.
    public func supermuxFlatRows(hidingProjectIDs shownProjectIDs: Set<String>) -> [MobileWorkspacePreview] {
        guard !shownProjectIDs.isEmpty else { return self }
        return filter { workspace in
            guard let projectID = workspace.supermuxProjectID, workspace.groupID == nil else {
                return true
            }
            let key = SupermuxProjectKey(
                pairingID: SupermuxMacSeam.pairingID(
                    macDeviceID: workspace.macDeviceID,
                    instanceTag: workspace.macInstanceTag
                ),
                projectID: projectID
            )
            return !shownProjectIDs.contains(key.rawValue) && !shownProjectIDs.contains(projectID)
        }
    }
}

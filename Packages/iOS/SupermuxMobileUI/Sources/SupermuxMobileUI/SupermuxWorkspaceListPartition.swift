public import CmuxMobileShellModel

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
    /// - Parameter hidingProjectAssociated: Whether folding is active. The
    ///   shell passes `false` while the Projects section is hidden
    ///   (disconnected or upstream host) and while searching/filtering, so no
    ///   workspace ever becomes unreachable or unsearchable.
    /// - Returns: The rows minus the ungrouped project-associated ones (or
    ///   unchanged when folding is off).
    public func supermuxFlatRows(hidingProjectAssociated: Bool) -> [MobileWorkspacePreview] {
        guard hidingProjectAssociated else { return self }
        return filter { $0.supermuxProjectID == nil || $0.groupID != nil }
    }
}

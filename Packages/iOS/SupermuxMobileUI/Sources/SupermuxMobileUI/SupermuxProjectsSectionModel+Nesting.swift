import Foundation

/// The inline-nesting half of ``SupermuxProjectsSectionModel`` (m6-f1): the
/// mac-sidebar-style per-project disclosure, its phone-local persistence,
/// the section-owned worktree sessions behind the nested rows, the nested
/// worktree open flow, and the detail-screen route — split from the main
/// file to respect the per-file length budget.
extension SupermuxProjectsSectionModel {
    /// Whether one project's inline disclosure is open.
    /// - Parameter projectID: The project's UUID string.
    public func isProjectExpanded(_ projectID: String) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    /// Toggles one project's inline disclosure, persisting the new state
    /// phone-locally. Expanding starts the project's section-owned worktree
    /// session (fetch on expand + `supermux.worktrees.updated` refetches);
    /// collapsing cancels it — a re-expand fetches fresh, like the mac
    /// sidebar's expand-refresh.
    /// - Parameter projectID: The project's UUID string.
    public func toggleProjectExpanded(_ projectID: String) {
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
            endWorktreeSession(forProjectID: projectID)
        } else {
            expandedProjectIDs.insert(projectID)
            startWorktreeSession(forProjectID: projectID)
        }
        expansionDefaults.set(expandedProjectIDs.sorted(), forKey: Self.expansionDefaultsKey)
    }

    /// Routes to the project DETAIL screen. Shared by the row's info
    /// accessory and its long-press menu entry (one action path).
    /// - Parameter projectID: The project's UUID string.
    public func openProjectDetail(_ projectID: String) {
        detailProjectID = projectID
    }

    /// Pops the detail route (navigation dismissed).
    public func dismissProjectDetail() {
        detailProjectID = nil
    }

    /// The freshest row snapshot for the routed detail project, or `nil`
    /// when nothing is routed (or the project/session went away — the
    /// destination shows a localized placeholder instead).
    public var detailRow: SupermuxProjectRowSnapshot? {
        guard let detailProjectID else { return nil }
        return snapshot.rows.first { $0.id == detailProjectID }
    }

    /// Navigates to a workspace through the shell's own closure — the ONE
    /// workspace-navigation path for the section's affordances. Pops any
    /// routed project detail first, so the destination binding never holds a
    /// stale `true` (which would swallow the next detail push).
    /// - Parameter workspaceID: The workspace's UI row id.
    func navigateToWorkspace(_ workspaceID: String) {
        dismissProjectDetail()
        selectWorkspaceAction(workspaceID)
    }

    /// Opens a nested worktree row: an already-open worktree navigates
    /// straight to its workspace; an unopened one runs the m2-f2
    /// `worktree.open` → navigate flow through the project's section-owned
    /// store. Failures surface on ``nestedOpenErrorMessage``. A late answer
    /// from a session that has since ended (disconnect/reconnect) is
    /// dropped: it must neither navigate the new shell with a stale
    /// workspace id nor surface an obsolete error.
    /// - Parameters:
    ///   - projectID: The owning project's UUID string.
    ///   - worktree: The tapped row's value snapshot.
    public func openNestedWorktree(projectID: String, worktree: SupermuxWorktreeRowSnapshot) {
        if let workspaceID = worktree.workspaceID {
            navigateToWorkspace(workspaceID)
            return
        }
        guard let store = worktreeSessions[projectID]?.store else { return }
        let generation = sessionGeneration
        Task {
            do {
                let workspaceID = try await store.openWorktree(path: worktree.path)
                guard sessionGeneration == generation else { return }
                if let workspaceID {
                    navigateToWorkspace(workspaceID)
                }
            } catch {
                guard sessionGeneration == generation else { return }
                nestedOpenErrorMessage = error.localizedDescription
            }
        }
    }

    /// Clears a surfaced nested-worktree open failure (alert dismissed).
    public func dismissNestedOpenError() {
        nestedOpenErrorMessage = nil
    }

    /// The nested-worktree slice for one EXPANDED project, projected from
    /// its section-owned worktrees store (a pure read — the store's
    /// `@Observable` fields re-project the snapshot as fetches land).
    func nestedWorktrees(forProjectID projectID: String) -> SupermuxProjectNestedWorktrees {
        guard let store = worktreeSessions[projectID]?.store else { return .unavailable }
        guard store.hasLoaded else { return .loading }
        return .loaded(SupermuxWorktreeRowSnapshot.unopenedRows(from: store.worktrees))
    }

    /// Starts the section-owned worktree session for one expanded project —
    /// a no-op while disconnected or without `supermux.worktrees.v1` (the
    /// nested slice stays ``SupermuxProjectNestedWorktrees/unavailable``).
    func startWorktreeSession(forProjectID projectID: String) {
        guard worktreeSessions[projectID] == nil,
              let store = makeWorktreesStore(forProjectID: projectID) else { return }
        let task = Task { await store.run() }
        worktreeSessions[projectID] = WorktreeSession(store: store, task: task)
    }

    func endWorktreeSession(forProjectID projectID: String) {
        worktreeSessions.removeValue(forKey: projectID)?.task.cancel()
    }

    /// Ends orphan worktree sessions whose project is no longer in the
    /// authoritative list (deleted mac-side): their rows are gone, so they
    /// could never be collapsed away, and without pruning they would refetch
    /// on every worktrees event forever. Persisted expansion ids are kept —
    /// they may belong to ANOTHER paired Mac's projects (ids are per-Mac
    /// UUIDs), and a stale id costs nothing while unconnected.
    /// - Parameter projectIDs: The fetched project ids.
    func pruneWorktreeSessions(keepingProjectIDs projectIDs: [String]) {
        let known = Set(projectIDs)
        for projectID in worktreeSessions.keys where !known.contains(projectID) {
            endWorktreeSession(forProjectID: projectID)
        }
    }

    func endAllWorktreeSessions() {
        for session in worktreeSessions.values {
            session.task.cancel()
        }
        worktreeSessions.removeAll()
    }
}

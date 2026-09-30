import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The inline-nesting half of ``SupermuxProjectsSectionModel`` (m6-f1): the
/// per-project disclosure and its phone-local persistence, the detail route,
/// and the flows that end in "navigate the shell to a workspace". All keyed
/// by project ROW id, so the same project id on two Macs never collides.
extension SupermuxProjectsSectionModel {
    /// Whether one project's inline disclosure is open.
    /// - Parameter projectID: The project ROW id.
    public func isProjectExpanded(_ projectID: String) -> Bool {
        isExpanded(SupermuxProjectKey(rawValue: projectID))
    }

    /// Whether a project's disclosure is open: by its own key, or by a
    /// legacy plain project id persisted before per-Mac keys.
    func isExpanded(_ key: SupermuxProjectKey) -> Bool {
        expandedProjectIDs.contains(key.rawValue) || expandedProjectIDs.contains(key.projectID)
    }

    /// The Mac-local ids of the projects expanded on one Mac.
    func expandedProjectIDs(onPairingID pairingID: String) -> Set<String> {
        Set(expandedProjectIDs.compactMap { rawValue in
            let key = SupermuxProjectKey(rawValue: rawValue)
            return key.pairingID.isEmpty || key.pairingID == pairingID ? key.projectID : nil
        })
    }

    /// Toggles one project's inline disclosure, persisting it phone-locally.
    /// Expanding starts the project's worktree session on its own Mac;
    /// collapsing cancels it.
    /// - Parameter projectID: The project ROW id.
    public func toggleProjectExpanded(_ projectID: String) {
        let key = SupermuxProjectKey(rawValue: projectID)
        let session = resolve(projectID)?.session
        if isExpanded(key) {
            expandedProjectIDs.remove(key.rawValue)
            expandedProjectIDs.remove(key.projectID)
            session?.endWorktreeSession(forProjectID: key.projectID)
        } else {
            expandedProjectIDs.insert(key.rawValue)
            session?.startWorktreeSession(forProjectID: key.projectID)
        }
        expansionDefaults.set(expandedProjectIDs.sorted(), forKey: Self.expansionDefaultsKey)
    }

    /// Routes to the project DETAIL screen, capturing the row as a fallback
    /// so the pushed detail survives its Mac's session going away.
    /// - Parameter projectID: The project ROW id.
    public func openProjectDetail(_ projectID: String) {
        detailFallbackRow = snapshot.rows.first { $0.id == projectID }
        detailProjectID = projectID
    }

    /// Pops the detail route (navigation dismissed).
    public func dismissProjectDetail() {
        detailProjectID = nil
        detailFallbackRow = nil
    }

    /// The freshest row for the routed detail project: the live row; `nil`
    /// (the "no longer available" placeholder) only when its Mac's LOADED
    /// list no longer contains it; otherwise the fallback captured at push.
    public var detailRow: SupermuxProjectRowSnapshot? {
        guard let detailProjectID else { return nil }
        let snapshot = snapshot
        if let live = snapshot.groups.lazy.flatMap(\.rows).first(where: { $0.id == detailProjectID }) {
            return live
        }
        let pairingID = SupermuxProjectKey(rawValue: detailProjectID).pairingID
        if snapshot.groups.contains(where: { $0.id == pairingID && $0.hasLoaded }) {
            return nil
        }
        return detailFallbackRow
    }

    /// Selects a workspace by its UI ROW id — the ONE selection path. Pops
    /// any routed detail first, so the destination binding never holds a
    /// stale `true`.
    /// - Parameter workspaceID: The workspace's row id.
    func navigateToWorkspace(_ workspaceID: String) {
        dismissProjectDetail()
        selectWorkspaceAction(workspaceID)
    }

    /// Navigates to a workspace a Mac answered with (its Mac-local id): the
    /// id is resolved against THAT Mac's rows, waiting for a freshly created
    /// workspace's row to arrive.
    /// - Parameters:
    ///   - remoteWorkspaceID: The Mac-local workspace id.
    ///   - mac: The Mac that answered, or `nil` when unknown.
    func navigateToMacWorkspace(_ remoteWorkspaceID: String, on mac: SupermuxMacInfo?) {
        navigator.open(SupermuxWorkspaceNavigator.Target(
            remoteWorkspaceID: remoteWorkspaceID,
            macDeviceID: mac?.macDeviceID,
            instanceTag: mac?.instanceTag
        ))
    }

    /// Opens a nested worktree row: an already-open worktree navigates to its
    /// workspace; an unopened one runs `worktree.open` on the project's Mac,
    /// then navigates. A late answer from an ended session, or one the user
    /// superseded with a newer open, never navigates or surfaces an error.
    /// - Parameters:
    ///   - projectID: The owning project's ROW id.
    ///   - worktree: The tapped row's value snapshot.
    public func openNestedWorktree(projectID: String, worktree: SupermuxWorktreeRowSnapshot) {
        nestedOpenRequestToken += 1
        let requestToken = nestedOpenRequestToken
        let resolved = resolve(projectID)
        if let workspaceID = worktree.workspaceID {
            navigateToMacWorkspace(workspaceID, on: resolved?.session.mac)
            return
        }
        guard let resolved, let store = resolved.session.worktreeSessions[resolved.projectID]?.store else { return }
        let session = resolved.session
        let generation = session.generation
        Task {
            do {
                let workspaceID = try await store.openWorktree(path: worktree.path)
                guard session.generation == generation, nestedOpenRequestToken == requestToken else { return }
                if let workspaceID {
                    navigateToMacWorkspace(workspaceID, on: session.mac)
                }
            } catch {
                guard session.generation == generation, nestedOpenRequestToken == requestToken else { return }
                nestedOpenErrorMessage = error.localizedDescription
            }
        }
    }

    /// Opens (or focuses) a workspace at the project ROOT on the project's own
    /// Mac and navigates to it — the twin of clicking a project row on the
    /// Mac. Shares the request token with the worktree open flow.
    /// - Parameter projectID: The project ROW id.
    public func openProjectWorkspace(_ projectID: String) {
        nestedOpenRequestToken += 1
        let requestToken = nestedOpenRequestToken
        guard let resolved = resolve(projectID), let store = resolved.session.store else { return }
        let session = resolved.session
        let generation = session.generation
        Task {
            do {
                let workspaceID = try await store.openProject(projectID: resolved.projectID)
                guard session.generation == generation, nestedOpenRequestToken == requestToken else { return }
                if let workspaceID {
                    navigateToMacWorkspace(workspaceID, on: session.mac)
                }
            } catch {
                guard session.generation == generation, nestedOpenRequestToken == requestToken else { return }
                nestedOpenErrorMessage = error.localizedDescription
            }
        }
    }

    /// Clears a surfaced open/navigation failure (alert dismissed).
    public func dismissNestedOpenError() {
        nestedOpenErrorMessage = nil
    }
}

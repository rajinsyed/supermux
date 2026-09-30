import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The closure bundle the section's rows act through. Every `projectID` a
/// row passes back is its ROW id; the model resolves it to the owning Mac's
/// session before any RPC, so a row always acts on its own Mac.
extension SupermuxProjectsSectionModel {
    /// The closure bundle row-level views act through.
    public var actions: SupermuxProjectsSectionActions {
        // Bound and annotated outside the initializer: an optional closure
        // forwarded into another optional closure parameter gives the type
        // checker nothing to anchor to inside an expression this large.
        var close: (@MainActor (_ workspaceID: String) -> Void)?
        if let closeWorkspaceAction {
            close = closeWorkspaceAction
        }
        return SupermuxProjectsSectionActions(
            toggleCollapsed: { [weak self] in self?.toggleCollapsed() },
            iconPNGData: { [weak self] projectID in
                await self?.iconPNGData(forProjectID: projectID) ?? nil
            },
            selectWorkspace: { [weak self] workspaceID in
                self?.navigateToWorkspace(workspaceID)
            },
            closeWorkspace: close,
            makeWorktreesStore: { [weak self] projectID in
                self?.makeWorktreesStore(forProjectID: projectID)
            },
            editing: editingActions,
            run: runActions,
            toggleProjectExpanded: { [weak self] projectID in
                self?.toggleProjectExpanded(projectID)
            },
            openProjectWorkspace: { [weak self] projectID in
                self?.openProjectWorkspace(projectID)
            },
            openProjectDetail: { [weak self] projectID in
                self?.openProjectDetail(projectID)
            },
            openNestedWorktree: { [weak self] projectID, worktree in
                self?.openNestedWorktree(projectID: projectID, worktree: worktree)
            },
            requestNestedWorktreeRemoval: { [weak self] projectID, worktree in
                self?.requestNestedWorktreeRemoval(projectID: projectID, worktree: worktree)
            },
            requestNewWorktree: { [weak self] projectID in
                _ = self?.requestNewWorktree(projectID)
            },
            preparingNewWorktreeProjectID: preparingNewWorktreeProjectID,
            makeAgentLaunchStore: { [weak self] projectID in
                self?.makeAgentLaunchStore(forProjectID: projectID)
            }
        )
    }

    /// Run/launch/action calls routed to each row's own Mac; `nil` while no
    /// Mac has a run store (every run affordance hides).
    private var runActions: SupermuxProjectRunActions? {
        guard orderedSessions.contains(where: { $0.runStore != nil }) else { return nil }
        return SupermuxProjectRunActions(
            startRun: { [weak self] projectID, commandID in
                let (store, id) = try Self.requireRunStore(self, projectID)
                try await store.startRun(projectID: id, commandID: commandID)
            },
            stopRun: { [weak self] projectID in
                let (store, id) = try Self.requireRunStore(self, projectID)
                try await store.stopRun(projectID: id)
            },
            launchPreset: { [weak self] presetID, projectID in
                let (store, id) = try Self.requireRunStore(self, projectID)
                return try await store.launchPreset(presetID: presetID, projectID: id)
            },
            runAction: { [weak self] projectID, actionID in
                let (store, id) = try Self.requireRunStore(self, projectID)
                return try await store.runAction(projectID: id, actionID: actionID)
            }
        )
    }

    /// The run store of a row's Mac plus the Mac-local project id, or
    /// `SupermuxMacUnavailableError` once that Mac's session is gone.
    private static func requireRunStore(
        _ model: SupermuxProjectsSectionModel?,
        _ rowID: String
    ) throws -> (SupermuxMobileRunStore, String) {
        guard let resolved = model?.resolve(rowID),
              let runStore = resolved.session.runStore else {
            throw SupermuxMacUnavailableError()
        }
        return (runStore, resolved.projectID)
    }
}

import Foundation
public import SupermuxMobileKit

/// Where one New Worktree create runs: a Mac's copy of the project, the
/// worktrees store (and Claude store) bound to THAT Mac's client, and how to
/// navigate to the workspace that Mac answers with.
struct SupermuxNewWorktreeTarget {
    /// The Mac the create runs on.
    let pairingID: String
    /// The project's display name on that Mac.
    let projectName: String
    /// The project's starting branch on that Mac, if configured.
    let defaultBranch: String?
    /// The store the create/suggest calls run through (that Mac's client).
    let store: SupermuxMobileWorktreesStore
    /// That Mac's Claude store, or `nil` without `supermux.agent_launch.v1`.
    let agentStore: SupermuxMobileAgentLaunchStore?
    /// Navigates to a workspace by the Mac-local id that Mac answered with.
    let openWorkspace: @MainActor (_ remoteWorkspaceID: String) -> Void
}

/// One presented New Worktree sheet: the requesting row, the Mac it opens
/// on, and every other Mac that has the same repository.
///
/// Deliberately NOT part of the section snapshot: it carries live stores and
/// is consumed only by the stable navigation wrapper above the list.
struct SupermuxNewWorktreePresentation {
    /// The project row the sheet was requested for.
    let row: SupermuxProjectRowSnapshot
    /// The create target on the row's own Mac.
    let target: SupermuxNewWorktreeTarget
    /// The Macs the sheet's picker offers (own Mac first); one entry hides it.
    let options: [SupermuxNewWorktreeMacOption]

    /// The own Mac's worktrees store.
    var store: SupermuxMobileWorktreesStore { target.store }
    /// The own Mac's Claude store, if any.
    var agentStore: SupermuxMobileAgentLaunchStore? { target.agentStore }
    /// Every Mac this presentation holds stores for.
    var pairingIDs: Set<String> { Set(options.map(\.pairingID) + [target.pairingID]) }
}

/// The sidebar's create-worktree flow (m7). Every entry point funnels
/// through ``requestNewWorktree(_:)`` — one shared action path — and the
/// sheet's Mac picker retargets the create through
/// ``prepareNewWorktreeTarget(_:)`` without switching the foreground Mac.
extension SupermuxProjectsSectionModel {
    /// Builds an agent-launch store on a project's own Mac, or `nil` when
    /// disconnected or that Mac lacks `supermux.agent_launch.v1`.
    /// - Parameter projectID: The project ROW id.
    public func makeAgentLaunchStore(forProjectID projectID: String) -> SupermuxMobileAgentLaunchStore? {
        guard let resolved = resolve(projectID) else { return nil }
        return resolved.session.makeAgentLaunchStore(forProjectID: resolved.projectID)
    }

    /// Prepares and presents the New Worktree sheet for one project: fetches
    /// an authoritative branch snapshot first (branch-only git changes emit
    /// no events), then presents with the Macs that share the repository.
    /// Failures surface on ``newWorktreeErrorMessage``.
    /// - Parameter projectID: The project ROW id.
    /// - Returns: The preparation task, or `nil` when the request cannot start.
    @discardableResult
    public func requestNewWorktree(_ projectID: String) -> Task<Void, Never>? {
        guard preparingNewWorktreeProjectID == nil, newWorktreePresentation == nil else { return nil }
        guard let row = snapshot.rows.first(where: { $0.id == projectID }),
              let resolved = resolve(projectID) else { return nil }
        let session = resolved.session
        // The expanded project's section-owned store when present (one
        // mutation path), else a minted one.
        guard let store = session.worktreeSessions[resolved.projectID]?.store
            ?? session.makeWorktreesStore(forProjectID: resolved.projectID) else { return nil }
        preparingNewWorktreeProjectID = projectID
        let generation = session.generation
        return Task {
            defer {
                // After a replacement reset the flow, a NEWER request owns
                // the marker — this stale task must not clear its spinner.
                if session.generation == generation, preparingNewWorktreeProjectID == projectID {
                    preparingNewWorktreeProjectID = nil
                }
            }
            do {
                // Only the branch snapshot gates presenting; the Claude
                // options load behind the open sheet.
                try await store.refreshBranches()
                guard session.generation == generation else { return }
                newWorktreePresentation = SupermuxNewWorktreePresentation(
                    row: row,
                    target: makeTarget(
                        session: session,
                        projectID: resolved.projectID,
                        projectName: row.name,
                        defaultBranch: row.defaultBranch,
                        store: store
                    ),
                    options: newWorktreeOptions(forProjectID: projectID)
                )
            } catch {
                guard session.generation == generation else { return }
                newWorktreeErrorPairingID = session.pairingID
                newWorktreeErrorMessage = error.localizedDescription
            }
        }
    }

    /// The Macs that can host a worktree of a project, own Mac first.
    /// - Parameter projectID: The project ROW id.
    func newWorktreeOptions(forProjectID projectID: String) -> [SupermuxNewWorktreeMacOption] {
        guard let resolved = resolve(projectID) else { return [] }
        let sources = orderedSessions.compactMap { session -> SupermuxNewWorktreeMacOptions.Source? in
            guard let store = session.store, store.hasLoaded else { return nil }
            return SupermuxNewWorktreeMacOptions.Source(
                mac: session.mac,
                supportsWorktrees: session.capabilities?.supportsWorktrees ?? false,
                projects: store.projects
            )
        }
        return SupermuxNewWorktreeMacOptions.options(
            forProjectID: resolved.projectID,
            onPairingID: resolved.session.pairingID,
            sources: sources
        )
    }

    /// Retargets a New Worktree create to another Mac's copy of the project:
    /// fetches that Mac's branches and returns stores bound to ITS client, so
    /// the create runs there without switching the foreground Mac.
    /// - Parameter option: The picked Mac.
    /// - Returns: The target the sheet creates through.
    func prepareNewWorktreeTarget(_ option: SupermuxNewWorktreeMacOption) async throws -> SupermuxNewWorktreeTarget {
        guard let session = sessions[option.pairingID],
              let project = session.store?.projects.first(where: { $0.id == option.projectID }),
              let store = session.worktreeSessions[option.projectID]?.store
                ?? session.makeWorktreesStore(forProjectID: option.projectID) else {
            throw SupermuxMacUnavailableError()
        }
        try await store.refreshBranches()
        return makeTarget(
            session: session,
            projectID: option.projectID,
            projectName: project.name,
            defaultBranch: project.defaultBranch,
            store: store
        )
    }

    private func makeTarget(
        session: SupermuxMacProjectsSession,
        projectID: String,
        projectName: String,
        defaultBranch: String?,
        store: SupermuxMobileWorktreesStore
    ) -> SupermuxNewWorktreeTarget {
        SupermuxNewWorktreeTarget(
            pairingID: session.pairingID,
            projectName: projectName,
            defaultBranch: defaultBranch,
            store: store,
            agentStore: session.makeAgentLaunchStore(forProjectID: projectID),
            openWorkspace: { [weak self, mac = session.mac] remoteWorkspaceID in
                self?.navigateToMacWorkspace(remoteWorkspaceID, on: mac)
            }
        )
    }

    /// Drops the presented sheet (dismissed or completed).
    public func dismissNewWorktree() {
        newWorktreePresentation = nil
    }

    /// Clears a surfaced preparation failure (alert dismissed).
    public func dismissNewWorktreeError() {
        newWorktreeErrorMessage = nil
    }

    /// Ends the create flow's transient state when its Mac's session goes
    /// away: the presentation's stores belong to the dead connection.
    func resetNewWorktreeFlow() {
        newWorktreePresentation = nil
        preparingNewWorktreeProjectID = nil
        newWorktreeErrorMessage = nil
    }
}

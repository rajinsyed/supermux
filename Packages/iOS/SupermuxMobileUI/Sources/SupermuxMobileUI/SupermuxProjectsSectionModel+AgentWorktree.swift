import Foundation
public import SupermuxMobileKit

/// One presented "Start Claude in a New Worktree" sheet: the project row it
/// was opened for, the agent-launch store (commands, models, start), and the
/// worktrees store whose branch snapshot feeds the starting-branch picker.
///
/// Deliberately NOT part of the section snapshot: it carries live stores and
/// is consumed only by the stable navigation wrapper above the list.
struct SupermuxAgentWorktreePresentation {
    /// The project the launch targets, as captured at request time.
    let row: SupermuxProjectRowSnapshot
    /// Options + start, already loaded.
    let agentStore: SupermuxMobileAgentLaunchStore
    /// Branch snapshot source for the starting-branch picker.
    let worktreesStore: SupermuxMobileWorktreesStore
}

/// The sidebar's prompt-first worktree launch: the project row's swipe
/// action, long-press menu entry, and inline nested row all funnel through
/// ``requestNewAgentWorktree(_:)`` — one shared action path. Mirrors the
/// plain New Worktree flow in `SupermuxProjectsSectionModel+NewWorktree.swift`.
extension SupermuxProjectsSectionModel {
    /// Builds an agent-launch store against the live session, or `nil` when
    /// disconnected or the host lacks `supermux.agent_launch.v1`.
    /// - Parameter projectID: The project's UUID string.
    public func makeAgentLaunchStore(forProjectID projectID: String) -> SupermuxMobileAgentLaunchStore? {
        guard let sessionClient, let sessionCapabilities,
              sessionCapabilities.supportsAgentLaunch else {
            return nil
        }
        return SupermuxMobileAgentLaunchStore(
            client: sessionClient,
            capabilities: sessionCapabilities,
            projectID: projectID
        )
    }

    /// Prepares and presents the sheet for one project: loads the Mac's
    /// launch options (commands + the selected command's models) and an
    /// authoritative branch snapshot concurrently, then presents. The
    /// requesting project shows a spinner meanwhile; failures surface on
    /// ``newWorktreeErrorMessage`` (visible, never silent).
    /// - Parameter projectID: The project's UUID string.
    /// - Returns: The preparation task, or `nil` when the request cannot start.
    @discardableResult
    public func requestNewAgentWorktree(_ projectID: String) -> Task<Void, Never>? {
        guard preparingAgentWorktreeProjectID == nil, agentWorktreePresentation == nil else { return nil }
        guard let row = snapshot.rows.first(where: { $0.id == projectID }) else { return nil }
        guard let agentStore = makeAgentLaunchStore(forProjectID: projectID),
              let worktreesStore = worktreeSessions[projectID]?.store
                ?? makeWorktreesStore(forProjectID: projectID) else { return nil }
        preparingAgentWorktreeProjectID = projectID
        let generation = sessionGeneration
        return Task {
            defer {
                if sessionGeneration == generation, preparingAgentWorktreeProjectID == projectID {
                    preparingAgentWorktreeProjectID = nil
                }
            }
            do {
                // Options and branches are independent Mac calls; the model
                // probe can take seconds on a cold command, so overlap them.
                async let options: Void = agentStore.loadOptions()
                try await worktreesStore.refreshBranches()
                await options
                guard sessionGeneration == generation else { return }
                if let optionsError = agentStore.optionsError {
                    newWorktreeErrorMessage = optionsError
                    return
                }
                agentWorktreePresentation = SupermuxAgentWorktreePresentation(
                    row: row,
                    agentStore: agentStore,
                    worktreesStore: worktreesStore
                )
            } catch {
                guard sessionGeneration == generation else { return }
                newWorktreeErrorMessage = error.localizedDescription
            }
        }
    }

    /// Drops the presented sheet (dismissed or completed).
    public func dismissNewAgentWorktree() {
        agentWorktreePresentation = nil
    }

    /// Ends the flow's transient state when its session goes away.
    func resetAgentWorktreeFlow() {
        agentWorktreePresentation = nil
        preparingAgentWorktreeProjectID = nil
    }
}

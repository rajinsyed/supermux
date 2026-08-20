import Foundation
import SupermuxMobileKit

/// One presented New Worktree sheet: the project row it was opened for and
/// the worktrees store its create/suggest calls run through.
///
/// Deliberately NOT part of the section snapshot: it carries a live store,
/// and it is consumed only by the stable navigation wrapper above the list —
/// never by a recycled row.
struct SupermuxNewWorktreePresentation {
    /// The project the sheet creates a worktree in, as captured at request
    /// time (name, default branch).
    let row: SupermuxProjectRowSnapshot
    /// The store the sheet's suggest/create closures call. An expanded
    /// project's section-owned store when one exists (one mutation path — its
    /// event loop refetches the nested rows the moment the create lands), a
    /// freshly minted one otherwise.
    let store: SupermuxMobileWorktreesStore
}

/// The sidebar's create-worktree flow (m7): the inline "New Worktree" row
/// under an expanded project, the project row's swipe action, and its
/// long-press menu entry all funnel through ``requestNewWorktree(_:)`` — one
/// shared action path, per the repo's shared-behavior policy.
///
/// Before this, creating a worktree from the phone took four steps
/// (long-press the project → Project Details → find the Worktrees header →
/// tap its small "+"). Now it is one gesture from the list itself, using the
/// exact same sheet and store calls the detail screen uses.
extension SupermuxProjectsSectionModel {
    /// Prepares and presents the New Worktree sheet for one project:
    /// fetches an authoritative branch snapshot first (branch-only git
    /// changes emit no worktree events, so a cached list is not trusted —
    /// the same rule as the detail screen), then presents.
    ///
    /// While the fetch is in flight ``preparingNewWorktreeProjectID`` marks
    /// the requesting project so its affordance can show a spinner. Failures
    /// surface on ``newWorktreeErrorMessage`` (UI-03: visible, never silent).
    /// - Parameter projectID: The project's UUID string.
    /// - Returns: The preparation task, or `nil` when the request cannot start.
    @discardableResult
    public func requestNewWorktree(_ projectID: String) -> Task<Void, Never>? {
        guard preparingNewWorktreeProjectID == nil, newWorktreePresentation == nil else { return nil }
        guard let row = snapshot.rows.first(where: { $0.id == projectID }) else { return nil }
        // The expanded project's section-owned store when present (its event
        // loop already follows this project), else a minted one — `nil` means
        // no session or no `supermux.worktrees.v1`, and every entry point to
        // this flow is already hidden in that case.
        guard let store = worktreeSessions[projectID]?.store
            ?? makeWorktreesStore(forProjectID: projectID) else { return nil }
        preparingNewWorktreeProjectID = projectID
        let generation = sessionGeneration
        return Task {
            defer {
                // Generation-guarded: after a session replacement has already
                // reset the flow, a NEWER request for the same project owns
                // the marker — this stale task must not clear its spinner.
                if sessionGeneration == generation, preparingNewWorktreeProjectID == projectID {
                    preparingNewWorktreeProjectID = nil
                }
            }
            do {
                try await store.refreshBranches()
                guard sessionGeneration == generation else { return }
                newWorktreePresentation = SupermuxNewWorktreePresentation(row: row, store: store)
            } catch {
                guard sessionGeneration == generation else { return }
                newWorktreeErrorMessage = error.localizedDescription
            }
        }
    }

    /// Drops the presented sheet (dismissed or completed).
    public func dismissNewWorktree() {
        newWorktreePresentation = nil
    }

    /// Clears a surfaced preparation failure (alert dismissed).
    public func dismissNewWorktreeError() {
        newWorktreeErrorMessage = nil
    }

    /// Ends the create flow's transient state when its session goes away
    /// (disconnect or replacement): the presentation's store belongs to the
    /// dead connection, and a sheet kept open over it could only fail. A
    /// surfaced preparation failure drops too — its alert describes the dead
    /// session, not the one replacing it.
    func resetNewWorktreeFlow() {
        newWorktreePresentation = nil
        preparingNewWorktreeProjectID = nil
        newWorktreeErrorMessage = nil
    }
}

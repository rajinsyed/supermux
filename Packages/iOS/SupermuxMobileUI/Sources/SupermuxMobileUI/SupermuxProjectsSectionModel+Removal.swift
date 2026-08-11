import Foundation
import SupermuxMobileKit

/// One worktree the user has swiped to remove, held while its confirmation is
/// on screen. Carries the project so the confirm can reach the right
/// section-owned store, and the branch so the dialog can name what it deletes.
public struct SupermuxPendingWorktreeRemoval: Equatable, Sendable {
    /// The owning project's UUID string.
    public let projectID: String
    /// The worktree's absolute path on the Mac (its stable identity).
    public let path: String
    /// The worktree's display name, for the dialog's title.
    public let displayName: String

    /// Memberwise initializer.
    /// - Parameters:
    ///   - projectID: The owning project's UUID string.
    ///   - path: The worktree's absolute path on the Mac.
    ///   - displayName: The worktree's display name.
    public init(projectID: String, path: String, displayName: String) {
        self.projectID = projectID
        self.path = path
        self.displayName = displayName
    }
}

/// The sidebar's swipe-to-remove flow for nested worktree rows.
///
/// The project DETAIL screen has had swipe-to-remove since m2; the sidebar's
/// nested rows showed the same worktrees with no way to act on them, so the
/// same gesture on the same object did different things depending on which
/// screen you reached it from. This closes that gap by driving the SAME
/// ``SupermuxMobileWorktreesStore`` removal state machine — one mutation path,
/// per the repo's shared-behavior policy — rather than adding a second one.
///
/// The full UI-03 contract is preserved: an always-shown first confirm, a
/// dirty worktree parking in confirm-force instead of failing silently, and a
/// visible alert for terminal failures.
extension SupermuxProjectsSectionModel {
    /// Asks to remove a nested worktree. Raises the first confirmation; it
    /// never deletes anything on its own.
    /// - Parameters:
    ///   - projectID: The owning project's UUID string.
    ///   - worktree: The swiped row's value snapshot.
    public func requestNestedWorktreeRemoval(
        projectID: String,
        worktree: SupermuxWorktreeRowSnapshot
    ) {
        // No session store means no way to remove it (disconnected, or the
        // host lacks `supermux.worktrees.v1`) — raising a dialog whose confirm
        // could only fail would be worse than ignoring the swipe.
        guard worktreeSessions[projectID]?.store != nil else { return }
        // Remembered so the force/failure dialogs can speak for the worktree
        // the user actually acted on, rather than whichever project won an
        // unordered dictionary scan.
        lastRemovalRequestProjectID = projectID
        pendingWorktreeRemoval = SupermuxPendingWorktreeRemoval(
            projectID: projectID,
            path: worktree.path,
            displayName: worktree.displayName
        )
    }

    /// Confirms the pending removal, running it through the project's
    /// section-owned store. A dirty worktree parks the store in
    /// `awaitingForceConfirmation`, which surfaces as the force dialog.
    public func confirmPendingWorktreeRemoval() {
        guard let pending = pendingWorktreeRemoval,
              let store = worktreeSessions[pending.projectID]?.store else {
            pendingWorktreeRemoval = nil
            return
        }
        pendingWorktreeRemoval = nil
        Task { await store.removeWorktree(path: pending.path) }
    }

    /// Confirms a FORCED removal of the worktree parked in the force-confirm
    /// state (uncommitted changes acknowledged).
    /// - Parameter projectID: The project whose store is parked.
    public func confirmForcedWorktreeRemoval(projectID: String) {
        guard let store = worktreeSessions[projectID]?.store,
              case let .awaitingForceConfirmation(path, _, _) = store.removal else { return }
        Task { await store.removeWorktree(path: path, force: true) }
    }

    /// Drops the pending first confirmation (dialog dismissed).
    public func dismissPendingWorktreeRemoval() {
        pendingWorktreeRemoval = nil
    }

    /// Resets a parked removal state on the project's store (force declined,
    /// or a failure acknowledged).
    /// - Parameter projectID: The project whose store is parked.
    public func dismissWorktreeRemovalState(projectID: String) {
        worktreeSessions[projectID]?.store.dismissRemoval()
    }

    /// The worktree currently awaiting a force confirmation, with the Mac's
    /// message; `nil` when none is.
    ///
    /// Reads the removal state off the STORE — the same place the detail
    /// screen reads it — so the two surfaces can never disagree about a
    /// removal's status.
    ///
    /// Resolution is by ``lastRemovalRequestProjectID`` first, not by
    /// dictionary iteration. `worktreeSessions` is unordered, so with two
    /// projects parked in confirm-force at once, iteration order would decide
    /// which one the single dialog spoke for — and the user could confirm a
    /// forced delete of a worktree they never swiped. The most recent request
    /// is the one the dialog is about; the fallback scan is sorted so that
    /// even the degenerate case is stable rather than arbitrary.
    public var forcedWorktreeRemovalPrompt: SupermuxWorktreeRemovalPrompt? {
        prompt { removal in
            guard case let .awaitingForceConfirmation(path, _, message) = removal else { return nil }
            return (path, message)
        }
    }

    /// The worktree whose removal failed terminally, with the user-facing
    /// message; `nil` when none did. Covers `confirmationStale` (an aborted
    /// force-remove) through the same alert, exactly as the detail screen
    /// does. Resolved with the same recency rule as the force prompt.
    public var failedWorktreeRemovalPrompt: SupermuxWorktreeRemovalPrompt? {
        prompt { removal in
            switch removal {
            case let .failed(path, message):
                return (path, message)
            case let .confirmationStale(path):
                return (
                    path,
                    String(
                        localized: "supermux.worktrees.remove.staleConfirmation",
                        defaultValue: "This worktree changed since you confirmed — nothing was removed. Try again.",
                        bundle: .module
                    )
                )
            default:
                return nil
            }
        }
    }

    /// Resolves a removal-state prompt: the most recently requested project
    /// first, then a deterministic scan of the rest.
    private func prompt(
        _ match: (SupermuxWorktreeRemovalState) -> (path: String, message: String)?
    ) -> SupermuxWorktreeRemovalPrompt? {
        func build(_ projectID: String) -> SupermuxWorktreeRemovalPrompt? {
            guard let store = worktreeSessions[projectID]?.store,
                  let hit = match(store.removal) else { return nil }
            return SupermuxWorktreeRemovalPrompt(
                projectID: projectID,
                displayName: SupermuxWorktreeRowSnapshot
                    .rows(from: store.worktrees)
                    .first { $0.path == hit.path }?
                    .displayName
                    ?? (hit.path as NSString).lastPathComponent,
                message: hit.message
            )
        }
        if let recent = lastRemovalRequestProjectID, let prompt = build(recent) {
            return prompt
        }
        for projectID in worktreeSessions.keys.sorted() {
            if let prompt = build(projectID) { return prompt }
        }
        return nil
    }
}

/// One worktree-removal prompt: which project it belongs to, which worktree it
/// names, and the Mac's message. Carrying the NAME is what lets the dialogs
/// say what they are about to delete instead of asking a generic question.
public struct SupermuxWorktreeRemovalPrompt: Equatable, Sendable {
    /// The owning project's UUID string.
    public let projectID: String
    /// The worktree's display name (branch, else the path's last component).
    public let displayName: String
    /// The Mac's user-facing message.
    public let message: String

    /// Memberwise initializer.
    /// - Parameters:
    ///   - projectID: The owning project's UUID string.
    ///   - displayName: The worktree's display name.
    ///   - message: The Mac's user-facing message.
    public init(projectID: String, displayName: String, message: String) {
        self.projectID = projectID
        self.displayName = displayName
        self.message = message
    }
}

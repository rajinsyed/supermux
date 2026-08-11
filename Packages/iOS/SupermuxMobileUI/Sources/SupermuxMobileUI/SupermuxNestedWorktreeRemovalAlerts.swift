import SwiftUI

/// The destructive-removal dressing for the sidebar's swipe-to-remove on
/// nested worktree rows: the always-shown first confirm, the dirty-worktree
/// force confirm, and the terminal-failure alert.
///
/// Attached by the section driver on the STABLE wrapper above the list, never
/// inside a row: the swiped row is inside a recycled UIKit cell, and a
/// presentation anchored there would be torn down with the cell mid-dialog.
///
/// Wording and flow are the project detail screen's, deliberately — the same
/// removal reached from two places must ask the same questions in the same
/// order (UI-03: a dirty worktree parks in confirm-force, never a silent
/// failure).
struct SupermuxNestedWorktreeRemovalAlerts: ViewModifier {
    let model: SupermuxProjectsSectionModel

    func body(content: Content) -> some View {
        // Read the observable state in body (not only inside Binding getters)
        // so observation tracking re-evaluates when it changes.
        let pending = model.pendingWorktreeRemoval
        let forced = model.forcedWorktreeRemovalPrompt
        let failed = model.failedWorktreeRemovalPrompt
        content
            .confirmationDialog(
                pending.map { candidate in
                    String(
                        localized: "supermux.worktrees.remove.confirm.title",
                        defaultValue: "Remove worktree “\(candidate.displayName)”?",
                        bundle: .module
                    )
                } ?? "",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { [weak model] presented in
                        if !presented { model?.dismissPendingWorktreeRemoval() }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    model.confirmPendingWorktreeRemoval()
                } label: {
                    Text(String(
                        localized: "supermux.worktrees.remove.confirm.action",
                        defaultValue: "Remove",
                        bundle: .module
                    ))
                }
                .accessibilityIdentifier("SupermuxNestedWorktreeRemoveConfirmButton")
                Button(role: .cancel) {
                    model.dismissPendingWorktreeRemoval()
                } label: {
                    Text(String(localized: "supermux.common.cancel", defaultValue: "Cancel", bundle: .module))
                }
            } message: {
                Text(String(
                    localized: "supermux.worktrees.remove.confirm.message",
                    defaultValue: "This deletes the worktree folder on your Mac.",
                    bundle: .module
                ))
            }
            .confirmationDialog(
                forced.map { prompt in
                    // Names the worktree: with two projects parked at once the
                    // user must be able to see WHICH uncommitted worktree this
                    // is about before force-deleting it.
                    String(
                        localized: "supermux.worktrees.remove.force.titleNamed",
                        defaultValue: "Remove worktree “\(prompt.displayName)” anyway?",
                        bundle: .module
                    )
                } ?? "",
                isPresented: Binding(
                    get: { forced != nil },
                    set: { [weak model] presented in
                        guard !presented, let projectID = forced?.projectID else { return }
                        model?.dismissWorktreeRemovalState(projectID: projectID)
                    }
                ),
                titleVisibility: .visible
            ) {
                if let forced {
                    Button(role: .destructive) {
                        model.confirmForcedWorktreeRemoval(projectID: forced.projectID)
                    } label: {
                        Text(String(
                            localized: "supermux.worktrees.remove.force.action",
                            defaultValue: "Remove Anyway",
                            bundle: .module
                        ))
                    }
                    .accessibilityIdentifier("SupermuxNestedWorktreeForceRemoveButton")
                    Button(role: .cancel) {
                        model.dismissWorktreeRemovalState(projectID: forced.projectID)
                    } label: {
                        Text(String(localized: "supermux.common.cancel", defaultValue: "Cancel", bundle: .module))
                    }
                }
            } message: {
                Text(String(
                    localized: "supermux.worktrees.remove.force.message",
                    defaultValue: "This worktree has uncommitted changes — remove it anyway?",
                    bundle: .module
                ))
            }
            .alert(
                String(
                    localized: "supermux.worktrees.remove.failed.title",
                    defaultValue: "Couldn’t Remove Worktree",
                    bundle: .module
                ),
                isPresented: Binding(
                    get: { failed != nil },
                    set: { [weak model] presented in
                        guard !presented, let projectID = failed?.projectID else { return }
                        model?.dismissWorktreeRemovalState(projectID: projectID)
                    }
                ),
                presenting: failed
            ) { _ in
                Button(role: .cancel) {
                    if let projectID = failed?.projectID {
                        model.dismissWorktreeRemovalState(projectID: projectID)
                    }
                } label: {
                    Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
                }
            } message: { prompt in
                Text(prompt.message)
            }
    }
}

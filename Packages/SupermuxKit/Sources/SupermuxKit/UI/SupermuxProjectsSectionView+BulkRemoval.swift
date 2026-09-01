import AppKit
import SwiftUI

/// The project row's "Delete All Worktrees…" flow: confirm (with an opt-in to
/// delete the branches too), remove every clean managed worktree, then offer
/// a second, explicit confirmation for the ones kept back because they have
/// uncommitted changes. Mirrors the per-worktree delete's dirty handling, just
/// batched.
extension SupermuxProjectsSectionView {
    /// Entry point wired to ``SupermuxProjectRowActions/deleteAllWorktrees``.
    @MainActor
    func deleteAllWorktrees(project: SupermuxProject) {
        let managed = (model.worktreesByProjectId[project.id] ?? []).filter(\.isSupermuxManaged)
        guard !managed.isEmpty else { return }
        guard let deleteBranches = confirmDeleteAllWorktrees(project: project, worktrees: managed) else { return }
        Task {
            var outcome = await model.removeAllWorktrees(projectId: project.id, deleteBranch: deleteBranches)
            if !outcome.dirty.isEmpty, confirmForceDeleteAll(outcome.dirty) {
                let forced = await model.removeWorktrees(
                    outcome.dirty,
                    projectId: project.id,
                    force: true,
                    deleteBranch: deleteBranches
                )
                outcome.removed += forced.removed
                outcome.failures += forced.failures
                outcome.dirty = forced.dirty
            }
            if !outcome.failures.isEmpty {
                presentBulkRemovalFailures(outcome.failures)
            }
        }
    }

    /// First confirmation. Returns `nil` when cancelled, otherwise whether the
    /// user also asked for the local branches to be deleted.
    @MainActor
    private func confirmDeleteAllWorktrees(project: SupermuxProject, worktrees: [SupermuxProjectWorktree]) -> Bool? {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.worktree.deleteAll.title",
            defaultValue: "Delete all worktrees of “\(project.name)”?"
        )
        alert.informativeText = String(
            localized: "supermux.worktree.deleteAll.message",
            defaultValue: "These worktrees and their files will be removed from disk:\n\n\(Self.bulletList(worktrees))"
        )
        alert.alertStyle = .warning
        let deleteBranches = NSButton(
            checkboxWithTitle: String(
                localized: "supermux.worktree.deleteAll.deleteBranches",
                defaultValue: "Also delete their local branches"
            ),
            target: nil,
            action: nil
        )
        deleteBranches.state = .off
        alert.accessoryView = deleteBranches
        alert.addButton(withTitle: String(localized: "supermux.worktree.deleteAll.confirm", defaultValue: "Delete All"))
        alert.addButton(withTitle: String(localized: "supermux.common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return deleteBranches.state == .on
    }

    /// Second confirmation for the worktrees the first pass kept back because
    /// they have uncommitted changes.
    @MainActor
    private func confirmForceDeleteAll(_ dirty: [SupermuxProjectWorktree]) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.worktree.deleteAll.dirty.title",
            defaultValue: "Some worktrees have uncommitted changes"
        )
        alert.informativeText = String(
            localized: "supermux.worktree.deleteAll.dirty.message",
            defaultValue: "These worktrees were kept because their uncommitted changes would be lost:\n\n\(Self.bulletList(dirty))\n\nDelete them anyway?"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "supermux.worktree.dirtyDelete.confirm", defaultValue: "Delete Anyway"))
        alert.addButton(withTitle: String(localized: "supermux.worktree.deleteAll.dirty.keep", defaultValue: "Keep Them"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Reports the worktrees whose removal failed terminally, one line each.
    @MainActor
    private func presentBulkRemovalFailures(_ failures: [SupermuxWorktreeBulkRemovalResult.Failure]) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.worktree.deleteAll.failed.title",
            defaultValue: "Some worktrees couldn’t be deleted"
        )
        alert.informativeText = failures
            .map { "• \($0.worktree.displayName): \($0.error.localizedDescription)" }
            .joined(separator: "\n")
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func bulletList(_ worktrees: [SupermuxProjectWorktree]) -> String {
        worktrees.map { "• \($0.displayName)" }.joined(separator: "\n")
    }
}

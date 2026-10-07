import AppKit

/// The sidebar's answers to ``SupermuxDeleteAllWorktreesFlow``'s questions:
/// a confirmation listing every worktree (with an opt-in to delete the
/// branches too), a second explicit confirmation for the ones kept back for
/// uncommitted changes, then a summary of anything that failed.
extension SupermuxDeleteAllWorktreesFlow {
    /// Runs the flow behind alerts.
    /// - Parameters:
    ///   - projectName: The project, for the confirmation title.
    ///   - macName: The other Mac the worktrees are on; `nil` for this Mac.
    ///   - name: A worktree's name in the alerts (its branch).
    ///   - path: A worktree's folder, shown beside its name: a worktree may
    ///     live anywhere, and the user should see what goes.
    public func runWithAlerts(
        projectName: String,
        macName: String?,
        name: (Worktree) -> String,
        path: (Worktree) -> String
    ) async {
        func describe(_ worktree: Worktree) -> String {
            "\(name(worktree)) — \((path(worktree) as NSString).abbreviatingWithTildeInPath)"
        }
        let outcome: Outcome?
        do {
            outcome = try await run(
                confirm: { Self.confirmDeleteAll($0, projectName: projectName, macName: macName, describe: describe) },
                confirmForce: { Self.confirmForceDeleteAll($0, describe: describe) }
            )
        } catch {
            Self.present(title: String(localized: "supermux.common.errorTitle", defaultValue: "Supermux"),
                         message: error.localizedDescription)
            return
        }
        guard let outcome else { return }
        if outcome.listed.isEmpty {
            Self.present(
                title: String(localized: "supermux.worktree.deleteAll.none", defaultValue: "There are no worktrees to delete."),
                message: ""
            )
        } else if !outcome.result.failures.isEmpty {
            Self.present(
                title: String(localized: "supermux.worktree.deleteAll.failed.title", defaultValue: "Some worktrees couldn’t be deleted"),
                message: outcome.result.failures
                    .map { "• \(name($0.worktree)): \($0.error.localizedDescription)" }
                    .joined(separator: "\n")
            )
        }
    }

    /// First confirmation. Returns `nil` when cancelled, otherwise whether the
    /// user also asked for the local branches to be deleted.
    private static func confirmDeleteAll(
        _ worktrees: [Worktree],
        projectName: String,
        macName: String?,
        describe: (Worktree) -> String
    ) -> Bool? {
        let alert = NSAlert()
        alert.messageText = if let macName {
            String(
                localized: "supermux.worktree.deleteAll.titleOnMac",
                defaultValue: "Delete all worktrees of “\(projectName)” on \(macName)?"
            )
        } else {
            String(
                localized: "supermux.worktree.deleteAll.title",
                defaultValue: "Delete all worktrees of “\(projectName)”?"
            )
        }
        alert.informativeText = String(
            localized: "supermux.worktree.deleteAll.message",
            defaultValue: "These worktrees and their files will be removed from disk:\n\n\(bulletList(worktrees, describe))"
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
    private static func confirmForceDeleteAll(_ dirty: [Worktree], describe: (Worktree) -> String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.worktree.deleteAll.dirty.title",
            defaultValue: "Some worktrees have uncommitted changes"
        )
        alert.informativeText = String(
            localized: "supermux.worktree.deleteAll.dirty.message",
            defaultValue: "These worktrees were kept because their uncommitted changes would be lost:\n\n\(bulletList(dirty, describe))\n\nDelete them anyway?"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "supermux.worktree.dirtyDelete.confirm", defaultValue: "Delete Anyway"))
        alert.addButton(withTitle: String(localized: "supermux.worktree.deleteAll.dirty.keep", defaultValue: "Keep Them"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func bulletList(_ worktrees: [Worktree], _ describe: (Worktree) -> String) -> String {
        worktrees.map { "• \(describe($0))" }.joined(separator: "\n")
    }
}

import AppKit
import SupermuxKit
import SwiftUI

/// The Changes panel for a selected device mirror: the same package panel,
/// fed by a model whose git runs on the owning Mac, under an "On <Mac>"
/// strip. Local-only affordances are withheld: the full diff viewer and the
/// PR viewer resolve a repository on THIS Mac's disk, which the mirror's
/// repository is not. File-row diffs still open (the patch text comes from
/// the owning Mac).
struct SupermuxMirrorChangesPanel: View {
    let model: SupermuxChangesModel
    let target: SupermuxMirrorTarget
    let isVisible: Bool
    let commitShortcut: KeyboardShortcut?
    let commitAcceleratorShortcut: KeyboardShortcut?
    let commitShortcutHint: String

    @EnvironmentObject private var tabManager: TabManager

    var body: some View {
        VStack(spacing: 0) {
            SupermuxRemoteHostBanner(
                title: String(
                    localized: "supermux.mirror.changes.onMac",
                    defaultValue: "On \(target.deviceName)"
                ),
                isConnected: target.isConnected
            )
            SupermuxChangesPanelView(
                model: model,
                isVisible: isVisible,
                commitShortcut: commitShortcut,
                commitAcceleratorShortcut: commitAcceleratorShortcut,
                commitShortcutHint: commitShortcutHint,
                onOpenDiff: nil,
                pullRequests: nil,
                knownPullRequest: nil,
                onOpenFileDiff: { [weak tabManager] patch in
                    guard let tabManager,
                          SupermuxFileDiffOpener.shared.present(patch, for: tabManager) else {
                        NSSound.beep()
                        return
                    }
                }
            )
        }
    }
}

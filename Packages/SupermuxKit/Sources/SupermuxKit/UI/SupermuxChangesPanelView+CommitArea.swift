import SwiftUI

/// The pinned commit area (message box, commit/push/pull buttons, key
/// equivalents) and the discard-confirmation helpers for
/// ``SupermuxChangesPanelView``.
///
/// Split out of the main panel file to keep it within the Swift file-length
/// budget; the stored properties these read are module-internal for exactly
/// this extension.
extension SupermuxChangesPanelView {

    // MARK: - Commit area

    var commitArea: some View {
        VStack(spacing: 6) {
            TextField(
                String(localized: "supermux.changes.commit.placeholder", defaultValue: "Commit message"),
                text: $model.commitMessage,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .font(.system(size: 11.5))
            Button {
                Task { await model.performCommit() }
            } label: {
                HStack(spacing: 4) {
                    if model.isAICommitMode {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                    }
                    Text(model.commitButtonTitle).font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            // The configured Commit chord (default ⌘↩) commits in every mode;
            // the invisible accelerator carries the second configured chord
            // (default ⇧⌘↩) for the same action. Both are editable in Settings.
            .keyboardShortcut(commitShortcut)
            .background(commitShiftReturnAccelerator)
            // `!isVisible` deactivates the window-wide ⌘↩ key equivalent while the
            // sidebar is hidden, so it cannot commit from a focused terminal/browser
            // when the panel is off-screen (it stays mounted after first show).
            .disabled(!model.canCommit || !isVisible)
            .help(commitHelp)
            HStack(spacing: 6) {
                Button { Task { await model.push() } } label: {
                    Text(pushTitle).font(.system(size: 11)).frame(maxWidth: .infinity)
                }
                .help(String(localized: "supermux.changes.push.help", defaultValue: "Push commits to the remote"))
                Button { Task { await model.pull() } } label: {
                    Text(pullTitle).font(.system(size: 11)).frame(maxWidth: .infinity)
                }
                .help(String(localized: "supermux.changes.pull.help", defaultValue: "Pull from the remote"))
            }
            .controlSize(.small)
            .disabled(model.isWorking)
        }
        .padding(8)
    }

    /// Invisible ⇧⌘↩ accelerator for the commit button.
    ///
    /// A SwiftUI `Button` carries a single `keyboardShortcut`, so a second combo
    /// for the same action needs its own button. This zero-size, transparent,
    /// accessibility-hidden button binds ⇧⌘↩ to ``SupermuxChangesModel/performCommit()``
    /// and shares the visible button's ``SupermuxChangesModel/canCommit`` gate, so
    /// ⇧⌘↩ commits in every mode without affecting layout or VoiceOver. Hosted via
    /// `.background` on the visible button so it never adds spacing to the stack.
    /// Gated on ``SupermuxChangesPanelView/isVisible`` for the same reason as the
    /// visible button: the key equivalent must not fire from a focused
    /// terminal/browser while the (still-mounted) panel is hidden.
    private var commitShiftReturnAccelerator: some View {
        Button {
            Task { await model.performCommit() }
        } label: {
            Color.clear.frame(width: 0, height: 0)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(commitAcceleratorShortcut)
        .disabled(!model.canCommit || !isVisible)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var commitHelp: String {
        model.isAICommitMode
            ? String(
                format: String(
                    localized: "supermux.changes.ai.commit.help",
                    defaultValue: "Stage all changes, generate a commit message with AI, and commit (%@)"
                ),
                commitShortcutHint
            )
            : String(
                format: String(
                    localized: "supermux.changes.commit.help",
                    defaultValue: "Commit staged changes (%@)"
                ),
                commitShortcutHint
            )
    }

    private var pushTitle: String {
        model.snapshot.ahead > 0
            ? String(localized: "supermux.changes.pushCount", defaultValue: "↑ Push \(model.snapshot.ahead)")
            : String(localized: "supermux.changes.push", defaultValue: "↑ Push")
    }

    private var pullTitle: String {
        model.snapshot.behind > 0
            ? String(localized: "supermux.changes.pullCount", defaultValue: "↓ Pull \(model.snapshot.behind)")
            : String(localized: "supermux.changes.pull", defaultValue: "↓ Pull")
    }

    // MARK: - Discard helpers

    var isDiscardDialogPresented: Binding<Bool> {
        Binding(
            get: { discardCandidate != nil },
            set: { if !$0 { discardCandidate = nil } }
        )
    }

    var discardAllMessage: String {
        String(
            localized: "supermux.changes.discardAll.message",
            defaultValue: "All staged and unstaged changes will be reverted and untracked files deleted. This cannot be undone."
        )
    }

    func discardMessage(for change: SupermuxGitFileChange) -> String {
        change.kind == .untracked
            ? String(
                localized: "supermux.changes.discard.untrackedMessage",
                defaultValue: "“\(change.fileName)” is untracked and will be deleted from disk. This cannot be undone."
            )
            : String(
                localized: "supermux.changes.discard.message",
                defaultValue: "Changes to “\(change.fileName)” will be permanently discarded. This cannot be undone."
            )
    }
}

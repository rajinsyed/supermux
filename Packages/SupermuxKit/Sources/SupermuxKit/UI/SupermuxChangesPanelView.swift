public import SwiftUI
import Foundation

/// Compact git changes panel for the cmux right sidebar.
///
/// A tiny SourceTree: shows the current branch with ahead/behind badges,
/// staged / unstaged / untracked files with hover stage / unstage / discard
/// actions, an expandable commit-history section, and a commit + push / pull
/// area pinned at the bottom. All state and git work lives in
/// ``SupermuxChangesModel``; this view only renders and dispatches.
public struct SupermuxChangesPanelView: View {
    // Internal (not private) so the section builders in
    // `SupermuxChangesPanelView+Sections.swift` can read them; the panel is
    // still the snapshot boundary and only hands value snapshots to rows.
    @Bindable var model: SupermuxChangesModel
    private let onOpenDiff: (() -> Void)?

    @State private var discardCandidate: SupermuxGitFileChange?
    @State private var isDiscardAllPresented = false
    @State var isHistoryExpanded = false
    @State var isIncomingExpanded = false

    /// How often the visible panel re-fetches in the background. Long enough to
    /// stay quiet (and out of git's way); workspace switches fetch immediately
    /// via the directory-keyed task regardless.
    private static let autoFetchInterval: Duration = .seconds(180)

    /// Creates the panel.
    /// - Parameters:
    ///   - model: Shared changes model owning git status and mutations.
    ///   - onOpenDiff: Host-app callback that opens a full diff view; the
    ///     "Open Diff" header button is hidden when `nil`.
    public init(model: SupermuxChangesModel, onOpenDiff: (() -> Void)?) {
        self.model = model
        self.onOpenDiff = onOpenDiff
    }

    /// The panel layout: header, scrollable change sections, error caption,
    /// and the pinned commit area.
    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.snapshot.isRepository {
                changeList
                Divider()
                if let error = model.lastError {
                    errorCaption(error)
                }
                commitArea
            } else {
                missingRepositoryHint
            }
        }
        .task { model.startObserving() }
        // Best-effort background fetch so behind/incoming reflect the remote
        // without a manual pull. Keyed on the directory so it restarts (and
        // fetches immediately) on a workspace switch — the exact moment a
        // just-merged worktree's commits become pullable on the main branch —
        // then re-fetches on a slow timer while the panel stays visible.
        // SwiftUI cancels the task on disappear / id change.
        .task(id: model.directory) {
            while !Task.isCancelled {
                await model.fetchAndRefresh()
                try? await Task.sleep(for: Self.autoFetchInterval)
            }
        }
        .onDisappear { model.stopObserving() }
        .confirmationDialog(
            String(localized: "supermux.changes.discard.title", defaultValue: "Discard Changes"),
            isPresented: isDiscardDialogPresented,
            titleVisibility: .visible,
            presenting: discardCandidate
        ) { change in
            Button(
                String(localized: "supermux.changes.discard.confirm", defaultValue: "Discard"),
                role: .destructive
            ) {
                Task { await model.discard(change) }
            }
            Button(String(localized: "supermux.changes.discard.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: { change in
            Text(discardMessage(for: change))
        }
        .confirmationDialog(
            String(localized: "supermux.changes.discardAll.title", defaultValue: "Discard All Changes"),
            isPresented: $isDiscardAllPresented,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "supermux.changes.discardAll.confirm", defaultValue: "Discard All"),
                role: .destructive
            ) {
                Task { await model.discardAll() }
            }
            Button(String(localized: "supermux.changes.discard.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(discardAllMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 5) {
            if model.snapshot.isRepository {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(branchTitle)
                    .font(.system(size: 11.5, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                trackingBadges
            } else {
                Text(String(localized: "supermux.changes.notARepository", defaultValue: "Not a git repository"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.isStashMenuAvailable {
                stashMenu
            }
            if model.snapshot.isRepository, model.snapshot.totalChangeCount > 0 {
                headerButton(
                    "trash",
                    help: String(localized: "supermux.changes.discardAll.help", defaultValue: "Discard all changes")
                ) {
                    isDiscardAllPresented = true
                }
            }
            if let onOpenDiff {
                headerButton(
                    "doc.text.magnifyingglass",
                    help: String(localized: "supermux.changes.openDiff.help", defaultValue: "Open diff view"),
                    action: onOpenDiff
                )
            }
            headerButton(
                "arrow.clockwise",
                help: String(localized: "supermux.changes.refresh.help", defaultValue: "Refresh status")
            ) {
                // Force a remote check too, so the user can pull the latest
                // incoming/behind status on demand without waiting for the timer.
                Task { await model.fetchAndRefresh() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var branchTitle: String {
        model.snapshot.branch
            ?? String(localized: "supermux.changes.detachedHead", defaultValue: "Detached HEAD")
    }

    @ViewBuilder
    private var trackingBadges: some View {
        if model.snapshot.ahead > 0 {
            trackingBadge(String(localized: "supermux.changes.aheadBadge", defaultValue: "↑\(model.snapshot.ahead)"))
        }
        if model.snapshot.behind > 0 {
            trackingBadge(String(localized: "supermux.changes.behindBadge", defaultValue: "↓\(model.snapshot.behind)"))
        }
    }

    private func trackingBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private func headerButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Stash

    private var stashMenu: some View {
        Menu {
            Button {
                Task { await model.stash(includeUntracked: false) }
            } label: {
                Label(
                    String(localized: "supermux.changes.stash.stash", defaultValue: "Stash Changes"),
                    systemImage: "tray.and.arrow.down"
                )
            }
            .disabled(!model.canStashTracked)

            Button {
                Task { await model.stash(includeUntracked: true) }
            } label: {
                Label(
                    String(
                        localized: "supermux.changes.stash.includeUntracked",
                        defaultValue: "Stash (Include Untracked)"
                    ),
                    systemImage: "tray.and.arrow.down"
                )
            }
            .disabled(!model.canStashIncludingUntracked)

            Divider()

            Button {
                Task { await model.popStash() }
            } label: {
                Label(
                    String(localized: "supermux.changes.stash.pop", defaultValue: "Pop Stash"),
                    systemImage: "tray.and.arrow.up"
                )
            }
            .disabled(!model.canPopStash)
        } label: {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isWorking)
        .help(String(localized: "supermux.changes.stash.help", defaultValue: "Stash operations"))
        .accessibilityLabel(String(localized: "supermux.changes.stash.help", defaultValue: "Stash operations"))
    }

    // MARK: - Change sections

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                // Show each sync section only when it has commits, so an
                // up-to-date branch stays uncluttered. The counts are
                // authoritative regardless of expansion (see the model).
                if model.incomingCount > 0 {
                    incomingSection
                }
                if model.outgoingCount > 0 {
                    historySection
                }
                if model.snapshot.totalChangeCount == 0 {
                    emptyState
                } else {
                    changeSection(
                        title: String(localized: "supermux.changes.section.staged", defaultValue: "Staged"),
                        changes: model.snapshot.staged,
                        actionTitle: String(localized: "supermux.changes.unstageAll", defaultValue: "Unstage All"),
                        sectionAction: { Task { await model.unstageAll() } },
                        isStaged: true
                    )
                    changeSection(
                        title: String(localized: "supermux.changes.section.unstaged", defaultValue: "Changes"),
                        changes: model.snapshot.unstaged,
                        actionTitle: String(localized: "supermux.changes.stageAll", defaultValue: "Stage All"),
                        sectionAction: { Task { await model.stageAll() } },
                        isStaged: false
                    )
                    changeSection(
                        title: String(localized: "supermux.changes.section.untracked", defaultValue: "Untracked"),
                        changes: model.snapshot.untracked,
                        actionTitle: String(localized: "supermux.changes.stageAll", defaultValue: "Stage All"),
                        sectionAction: { stageAllUntracked() },
                        isStaged: false
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        Text(String(localized: "supermux.changes.empty", defaultValue: "No changes"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    @ViewBuilder
    private func changeSection(
        title: String, changes: [SupermuxGitFileChange], actionTitle: String,
        sectionAction: @escaping () -> Void, isStaged: Bool
    ) -> some View {
        if !changes.isEmpty {
            sectionHeader(title: title, count: changes.count, actionTitle: actionTitle, action: sectionAction)
            ForEach(changes) { change in
                SupermuxChangeRowView(
                    change: change,
                    onStage: isStaged ? nil : { stage(change) },
                    onUnstage: isStaged ? { unstage(change) } : nil,
                    onDiscard: isStaged ? nil : { discardCandidate = change }
                )
            }
        }
    }

    private func sectionHeader(
        title: String, count: Int, actionTitle: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer(minLength: 0)
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .disabled(model.isWorking)
        }
        .padding(.horizontal, 5)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func stageAllUntracked() {
        let untracked = model.snapshot.untracked
        Task {
            for change in untracked { await model.stage(change) }
        }
    }

    private func stage(_ change: SupermuxGitFileChange) {
        Task { await model.stage(change) }
    }

    private func unstage(_ change: SupermuxGitFileChange) {
        Task { await model.unstage(change) }
    }

    // MARK: - Commit area

    private var commitArea: some View {
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
            // ⌘↩ commits in every mode (typed message or AI "Generate & Commit");
            // the invisible accelerator binds ⇧⌘↩ to the same action so the user's
            // shift-modified muscle memory works whether or not a message is typed.
            .keyboardShortcut(.return, modifiers: .command)
            .background(commitShiftReturnAccelerator)
            .disabled(!model.canCommit)
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
    private var commitShiftReturnAccelerator: some View {
        Button {
            Task { await model.performCommit() }
        } label: {
            Color.clear.frame(width: 0, height: 0)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .disabled(!model.canCommit)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var commitHelp: String {
        model.isAICommitMode
            ? String(
                localized: "supermux.changes.ai.commit.help",
                defaultValue: "Stage all changes, generate a commit message with AI, and commit (⌘↩ or ⇧⌘↩)"
            )
            : String(localized: "supermux.changes.commit.help", defaultValue: "Commit staged changes (⌘↩ or ⇧⌘↩)")
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

    // MARK: - Error / placeholder

    private func errorCaption(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10.5))
            .foregroundStyle(.red)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    private var missingRepositoryHint: some View {
        Text(String(
            localized: "supermux.changes.notARepository.hint",
            defaultValue: "Open a folder inside a git repository to see changes."
        ))
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: - Discard helpers

    private var isDiscardDialogPresented: Binding<Bool> {
        Binding(
            get: { discardCandidate != nil },
            set: { if !$0 { discardCandidate = nil } }
        )
    }

    private var discardAllMessage: String {
        String(
            localized: "supermux.changes.discardAll.message",
            defaultValue: "All staged and unstaged changes will be reverted and untracked files deleted. This cannot be undone."
        )
    }

    private func discardMessage(for change: SupermuxGitFileChange) -> String {
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

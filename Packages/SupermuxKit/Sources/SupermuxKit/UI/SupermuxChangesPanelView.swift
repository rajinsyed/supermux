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
    /// Whether the right sidebar is actually on-screen. The sidebar keeps the
    /// changes panel mounted after its first show (so re-showing is instant), so
    /// the panel gates visibility-dependent work itself: the file-system-watcher
    /// observation and the background auto-fetch pause while hidden (no git
    /// spawns for an off-screen panel), and the window-wide commit key
    /// equivalents (⌘↩ / ⇧⌘↩) deactivate so they cannot commit from a focused
    /// terminal/browser while the panel is not even visible. Internal (not
    /// private) so the commit-area extension can read it.
    let isVisible: Bool
    /// Configured key equivalent for Commit (default ⌘↩); `nil` when unbound.
    /// Supplied by the host so the chord is editable in Settings / `cmux.json`.
    let commitShortcut: KeyboardShortcut?
    /// Configured key equivalent for the second commit chord (default ⇧⌘↩).
    let commitAcceleratorShortcut: KeyboardShortcut?
    /// Display string for the primary commit chord, shown in the button's help.
    let commitShortcutHint: String

    @State var discardCandidate: SupermuxGitFileChange?
    @State var isDiscardAllPresented = false
    @State var isHistoryExpanded = false
    @State var isIncomingExpanded = false

    /// How often the visible panel re-fetches in the background. Long enough to
    /// stay quiet (and out of git's way); workspace switches fetch immediately
    /// via the directory-keyed task regardless.
    private static let autoFetchInterval: Duration = .seconds(180)

    /// Identity for the auto-fetch `.task`: it restarts on a workspace switch and
    /// pauses (the task body returns immediately) while the sidebar is hidden.
    private struct AutoFetchKey: Equatable {
        let directory: String?
        let isVisible: Bool
    }

    /// Creates the panel.
    /// - Parameters:
    ///   - model: Shared changes model owning git status and mutations.
    ///   - isVisible: Whether the right sidebar is currently shown; gates the
    ///     file-system-watcher observation, the background auto-fetch, and the
    ///     commit key equivalents (defaults to `true` for callers —
    ///     previews/tests — with no sidebar lifecycle).
    ///   - commitShortcut: Configured key equivalent for Commit (default ⌘↩).
    ///   - commitAcceleratorShortcut: Configured second commit chord (default ⇧⌘↩).
    ///   - commitShortcutHint: Display string for the primary chord (button help).
    ///   - onOpenDiff: Host-app callback that opens a full diff view; the
    ///     "Open Diff" header button is hidden when `nil`.
    public init(
        model: SupermuxChangesModel,
        isVisible: Bool = true,
        commitShortcut: KeyboardShortcut? = KeyboardShortcut(.return, modifiers: .command),
        commitAcceleratorShortcut: KeyboardShortcut? = KeyboardShortcut(.return, modifiers: [.command, .shift]),
        commitShortcutHint: String = "⌘↩",
        onOpenDiff: (() -> Void)?
    ) {
        self.model = model
        self.isVisible = isVisible
        self.commitShortcut = commitShortcut
        self.commitAcceleratorShortcut = commitAcceleratorShortcut
        self.commitShortcutHint = commitShortcutHint
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
        // FS-event observation only while the sidebar is actually visible: the
        // panel stays mounted after first show, so an unkeyed task would keep
        // spawning git on every file-system batch behind a hidden sidebar.
        // startObserving() refreshes immediately, so state is fresh again on
        // every re-show; a directory switch while hidden still refreshes once
        // via setDirectory's observeTask == nil branch.
        .task(id: isVisible) {
            if isVisible {
                model.startObserving()
            } else {
                model.stopObserving()
            }
        }
        // Best-effort background fetch so behind/incoming reflect the remote
        // without a manual pull. Keyed on the directory *and* visibility so it
        // restarts (and fetches immediately) on a workspace switch — the exact
        // moment a just-merged worktree's commits become pullable on the main
        // branch — and pauses entirely while the sidebar is hidden (the panel
        // stays mounted after first show, so an unkeyed task would keep fetching
        // off-screen). SwiftUI cancels the task on disappear / id change.
        .task(id: AutoFetchKey(directory: model.directory, isVisible: isVisible)) {
            guard isVisible else { return }
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
        // One batched `git add` + one refresh for the whole section — never a
        // per-file mutation/refresh cycle (hundreds of process spawns).
        let untracked = model.snapshot.untracked
        Task { await model.stage(changes: untracked) }
    }

    private func stage(_ change: SupermuxGitFileChange) {
        Task { await model.stage(change) }
    }

    private func unstage(_ change: SupermuxGitFileChange) {
        Task { await model.unstage(change) }
    }

    // MARK: - Commit area
    //
    // The commit box, commit/push/pull buttons, and the discard confirmation
    // helpers live in `SupermuxChangesPanelView+CommitArea.swift` to keep this
    // file within the Swift file-length budget.

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

}

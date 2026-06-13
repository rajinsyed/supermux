public import SwiftUI
import Foundation

/// Compact git changes panel for the cmux right sidebar.
///
/// A tiny SourceTree: shows the current branch with ahead/behind badges,
/// staged / unstaged / untracked files with hover stage / unstage / discard
/// actions, and a commit + push / pull area pinned at the bottom. All state
/// and git work lives in ``SupermuxChangesModel``; this view only renders and
/// dispatches.
public struct SupermuxChangesPanelView: View {
    @Bindable private var model: SupermuxChangesModel
    private let onOpenDiff: (() -> Void)?

    @State private var discardCandidate: SupermuxGitFileChange?

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
        .task {
            await model.refresh()
            model.startPolling()
        }
        .onDisappear { model.stopPolling() }
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
                Task { await model.refresh() }
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

    // MARK: - Change sections

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
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
                Task { await model.commit() }
            } label: {
                Text(String(localized: "supermux.changes.commit", defaultValue: "Commit"))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isCommitDisabled)
            .help(String(localized: "supermux.changes.commit.help", defaultValue: "Commit staged changes (⌘↩)"))
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

    private var isCommitDisabled: Bool {
        model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.snapshot.staged.isEmpty
            || model.isWorking
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

// MARK: - Row

/// One file row: kind badge, file name, directory, and hover actions.
struct SupermuxChangeRowView: View {
    let change: SupermuxGitFileChange
    let onStage: (() -> Void)?
    let onUnstage: (() -> Void)?
    let onDiscard: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            kindBadge
            Text(change.fileName)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
            if let directory = change.directory {
                Text(directory)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if isHovering {
                hoverActions
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(isHovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
        .help(change.path)
    }

    private var kindBadge: some View {
        Text(kindBadgeStyle.letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(kindBadgeStyle.color)
            .frame(width: 14, height: 14)
            .background(kindBadgeStyle.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            .help(kindLabel)
            .accessibilityLabel(kindLabel)
    }

    @ViewBuilder
    private var hoverActions: some View {
        if let onDiscard {
            rowButton(
                "arrow.uturn.backward",
                help: String(localized: "supermux.changes.row.discard.help", defaultValue: "Discard changes"),
                action: onDiscard
            )
        }
        if let onStage {
            rowButton(
                "plus",
                help: String(localized: "supermux.changes.row.stage.help", defaultValue: "Stage file"),
                action: onStage
            )
        }
        if let onUnstage {
            rowButton(
                "minus",
                help: String(localized: "supermux.changes.row.unstage.help", defaultValue: "Unstage file"),
                action: onUnstage
            )
        }
    }

    private func rowButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var kindBadgeStyle: (letter: String, color: Color) {
        switch change.kind {
        case .modified: ("M", .yellow)
        case .added: ("A", .green)
        case .deleted: ("D", .red)
        case .renamed: ("R", .blue)
        case .copied: ("C", .blue)
        case .untracked: ("U", .secondary)
        case .conflicted: ("!", .orange)
        case .typeChanged: ("T", .yellow)
        }
    }

    private var kindLabel: String {
        switch change.kind {
        case .modified: String(localized: "supermux.changes.kind.modified", defaultValue: "Modified")
        case .added: String(localized: "supermux.changes.kind.added", defaultValue: "Added")
        case .deleted: String(localized: "supermux.changes.kind.deleted", defaultValue: "Deleted")
        case .renamed: String(localized: "supermux.changes.kind.renamed", defaultValue: "Renamed")
        case .copied: String(localized: "supermux.changes.kind.copied", defaultValue: "Copied")
        case .untracked: String(localized: "supermux.changes.kind.untracked", defaultValue: "Untracked")
        case .conflicted: String(localized: "supermux.changes.kind.conflicted", defaultValue: "Conflicted")
        case .typeChanged: String(localized: "supermux.changes.kind.typeChanged", defaultValue: "Type changed")
        }
    }
}

public import SupermuxMobileKit
public import SwiftUI

/// The workspace changes screen: branch summary, staged / unstaged /
/// untracked sections with swipe stage/unstage actions, a destructive
/// discard confirm, and per-file navigation into ``SupermuxDiffScreen``.
///
/// Owns one ``SupermuxMobileChangesStore`` session per presentation, run
/// inside a `.task` keyed on the scene phase — so the Mac-side watch is
/// heartbeated only while the screen is foregrounded and released
/// (`enable:false`) when it disappears or the app backgrounds.
public struct SupermuxChangesScreen: View {
    private let workspaceName: String
    private let makeStore: @MainActor () -> SupermuxMobileChangesStore?

    /// The presentation-owned changes session; `nil` while disconnected.
    @State private var store: SupermuxMobileChangesStore?
    /// The row awaiting the (always-shown) destructive discard confirm.
    @State private var discardCandidate: SupermuxChangedFileRowSnapshot?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Creates the changes screen.
    /// - Parameters:
    ///   - workspaceName: The workspace's display name (navigation title).
    ///   - makeStore: Builds the changes store against the live session, or
    ///     `nil` when disconnected (a not-connected placeholder shows).
    public init(
        workspaceName: String,
        makeStore: @escaping @MainActor () -> SupermuxMobileChangesStore?
    ) {
        self.workspaceName = workspaceName
        self.makeStore = makeStore
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(workspaceName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .accessibilityIdentifier("SupermuxChangesScreen")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text(String(
                                localized: "supermux.common.done",
                                defaultValue: "Done",
                                bundle: .module
                            ))
                        }
                        .accessibilityIdentifier("SupermuxChangesDoneButton")
                    }
                }
                .navigationDestination(for: SupermuxChangedFileRowSnapshot.self) { row in
                    SupermuxDiffScreen(path: row.path) {
                        guard let store else { throw SupermuxChangesScreenError.notConnected }
                        return try await store.loadDiff(path: row.path, staged: row.diffIsStaged)
                    }
                }
        }
        // One session per foreground stint: backgrounding flips the id, which
        // cancels `run()` (sending the final `enable:false`); returning to the
        // foreground re-runs it against the SAME store (re-subscribe, re-watch).
        .task(id: scenePhase == .background) {
            guard scenePhase != .background else { return }
            let store = self.store ?? makeStore()
            self.store = store
            guard let store else { return }
            await store.run()
        }
        .confirmationDialog(
            discardCandidate.map { candidate in
                String(
                    localized: "supermux.changes.discard.confirm.title",
                    defaultValue: "Discard changes to “\(candidate.fileName)”?",
                    bundle: .module
                )
            } ?? "",
            isPresented: Binding(
                get: { discardCandidate != nil },
                set: { if !$0 { discardCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: discardCandidate
        ) { candidate in
            Button(role: .destructive) {
                let store = store
                Task { await store?.discard(paths: [candidate.path]) }
            } label: {
                Text(String(
                    localized: "supermux.changes.discard.confirm.action",
                    defaultValue: "Discard",
                    bundle: .module
                ))
            }
        } message: { candidate in
            // Desktop-parity truth in the copy: discard restores TRACKED
            // files to their last commit; an untracked file is deleted.
            if candidate.area == .untracked {
                Text(String(
                    localized: "supermux.changes.discard.confirm.untrackedMessage",
                    defaultValue: "This file was never committed — discarding permanently deletes it from your Mac.",
                    bundle: .module
                ))
            } else {
                Text(String(
                    localized: "supermux.changes.discard.confirm.message",
                    defaultValue: "This restores the file on your Mac to its last committed state.",
                    bundle: .module
                ))
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let store {
            if store.hasLoaded {
                if store.status?.isRepository == false {
                    placeholder(String(
                        localized: "supermux.changes.notRepository",
                        defaultValue: "This workspace is not a git repository.",
                        bundle: .module
                    ))
                } else {
                    changesList(store)
                }
            } else {
                loadingPlaceholder
            }
        } else {
            placeholder(String(
                localized: "supermux.changes.notConnected",
                defaultValue: "Not connected to a Mac.",
                bundle: .module
            ))
        }
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(String(
                localized: "supermux.changes.loading",
                defaultValue: "Loading changes…",
                bundle: .module
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changesList(_ store: SupermuxMobileChangesStore) -> some View {
        let status = store.status
        let staged = SupermuxChangedFileRowSnapshot.rows(from: status?.staged, area: .staged)
        let unstaged = SupermuxChangedFileRowSnapshot.rows(from: status?.unstaged, area: .unstaged)
        let untracked = SupermuxChangedFileRowSnapshot.rows(from: status?.untracked, area: .untracked)
        let actionsDisabled = store.isMutating
        return List {
            SupermuxChangesSummarySection(
                branch: status?.branch,
                ahead: status?.ahead ?? 0,
                behind: status?.behind ?? 0,
                errorDescription: store.lastErrorDescription
            )
            if staged.isEmpty, unstaged.isEmpty, untracked.isEmpty {
                Section {
                    Text(String(
                        localized: "supermux.changes.empty",
                        defaultValue: "No changes",
                        bundle: .module
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            if !staged.isEmpty {
                SupermuxChangedFilesSection(
                    title: String(
                        localized: "supermux.changes.section.staged",
                        defaultValue: "Staged",
                        bundle: .module
                    ),
                    rows: staged,
                    actionsDisabled: actionsDisabled,
                    headerAction: SupermuxChangesSectionHeaderAction(
                        title: String(
                            localized: "supermux.changes.action.unstageAll",
                            defaultValue: "Unstage All",
                            bundle: .module
                        ),
                        identifier: "SupermuxChangesUnstageAllButton",
                        perform: { let store = store; Task { await store.unstageAll() } }
                    ),
                    unstage: { row in
                        let store = store
                        Task { await store.unstage(paths: [row.path]) }
                    }
                )
            }
            if !unstaged.isEmpty {
                SupermuxChangedFilesSection(
                    title: String(
                        localized: "supermux.changes.section.unstaged",
                        defaultValue: "Changes",
                        bundle: .module
                    ),
                    rows: unstaged,
                    actionsDisabled: actionsDisabled,
                    headerAction: SupermuxChangesSectionHeaderAction(
                        title: String(
                            localized: "supermux.changes.action.stageAll",
                            defaultValue: "Stage All",
                            bundle: .module
                        ),
                        identifier: "SupermuxChangesStageAllButton",
                        perform: { let store = store; Task { await store.stageAll() } }
                    ),
                    stage: { row in
                        let store = store
                        Task { await store.stage(paths: [row.path]) }
                    },
                    requestDiscard: { discardCandidate = $0 }
                )
            }
            if !untracked.isEmpty {
                SupermuxChangedFilesSection(
                    title: String(
                        localized: "supermux.changes.section.untracked",
                        defaultValue: "Untracked",
                        bundle: .module
                    ),
                    rows: untracked,
                    actionsDisabled: actionsDisabled,
                    stage: { row in
                        let store = store
                        Task { await store.stage(paths: [row.path]) }
                    },
                    requestDiscard: { discardCandidate = $0 }
                )
            }
        }
    }
}

/// Thrown when a diff is requested after the session went away (the diff
/// screen renders it in its retry state).
private enum SupermuxChangesScreenError: Error {
    case notConnected
}

/// The branch summary header: branch name, ahead/behind counts, and the
/// store's non-blocking error surface. Values only — no store reference.
struct SupermuxChangesSummarySection: View {
    let branch: String?
    let ahead: Int
    let behind: Int
    let errorDescription: String?

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(
                        localized: "supermux.changes.branchLabel",
                        defaultValue: "Branch",
                        bundle: .module
                    ))
                Text(branch ?? String(
                    localized: "supermux.changes.detachedHead",
                    defaultValue: "Detached HEAD",
                    bundle: .module
                ))
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 4)
                if ahead > 0 {
                    Text(verbatim: "↑\(ahead)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(
                            localized: "supermux.changes.ahead",
                            defaultValue: "\(ahead) commits ahead",
                            bundle: .module
                        ))
                }
                if behind > 0 {
                    Text(verbatim: "↓\(behind)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(
                            localized: "supermux.changes.behind",
                            defaultValue: "\(behind) commits behind",
                            bundle: .module
                        ))
                }
            }
            if let errorDescription {
                Text(errorDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("SupermuxChangesError")
            }
        }
    }
}

/// A closure bundle for a section header's trailing action (Stage All /
/// Unstage All).
struct SupermuxChangesSectionHeaderAction {
    let title: String
    let identifier: String
    let perform: @MainActor () -> Void
}

/// One bucket of changed files: header (+ optional bulk action) and rows.
/// Rows receive immutable snapshots plus closures only.
struct SupermuxChangedFilesSection: View {
    let title: String
    let rows: [SupermuxChangedFileRowSnapshot]
    let actionsDisabled: Bool
    var headerAction: SupermuxChangesSectionHeaderAction?
    var stage: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?
    var unstage: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?
    var requestDiscard: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?

    var body: some View {
        Section {
            ForEach(rows) { row in
                SupermuxChangedFileMobileRow(
                    row: row,
                    actionsDisabled: actionsDisabled,
                    stage: stage,
                    unstage: unstage,
                    requestDiscard: requestDiscard
                )
            }
        } header: {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 0)
                if let headerAction {
                    Button(action: headerAction.perform) {
                        Text(headerAction.title)
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier(headerAction.identifier)
                }
            }
        }
    }
}

/// One changed-file row: status letter, emphasized filename over its
/// de-emphasized directory, swipe actions, and navigation into the diff.
struct SupermuxChangedFileMobileRow: View {
    let row: SupermuxChangedFileRowSnapshot
    let actionsDisabled: Bool
    var stage: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?
    var unstage: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?
    var requestDiscard: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?

    var body: some View {
        NavigationLink(value: row) {
            HStack(spacing: 10) {
                Text(verbatim: row.kindBadge)
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(badgeTint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.fileName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let directory = row.directory {
                        Text(directory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let requestDiscard {
                Button(role: .destructive) {
                    requestDiscard(row)
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.changes.action.discard",
                            defaultValue: "Discard",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
                .disabled(actionsDisabled)
            }
            if let stage {
                Button {
                    stage(row)
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.changes.action.stage",
                            defaultValue: "Stage",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "plus.circle")
                    }
                }
                .tint(.green)
                .disabled(actionsDisabled)
            }
            if let unstage {
                Button {
                    unstage(row)
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.changes.action.unstage",
                            defaultValue: "Unstage",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "minus.circle")
                    }
                }
                .tint(.orange)
                .disabled(actionsDisabled)
            }
        }
        .accessibilityLabel(row.fileName)
        .accessibilityValue(row.directory ?? "")
        .accessibilityIdentifier("SupermuxChangedFileRow-\(row.id)")
    }

    /// Status tint following the desktop's changes-list convention:
    /// additions/untracked green, deletions red, everything else neutral.
    private var badgeTint: Color {
        switch row.kind {
        case "added", "untracked": .green
        case "deleted": .red
        case "conflicted": .orange
        default: .secondary
        }
    }
}

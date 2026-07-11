public import SupermuxMobileKit
public import SwiftUI

/// The workspace changes screen, in two segments. Changes: branch summary,
/// commit composer (with the one-tap Generate & Commit flow while the draft
/// is empty), staged / unstaged / untracked sections with swipe stage/unstage
/// actions, a destructive discard confirm, per-file navigation into
/// ``SupermuxDiffScreen``, and a push/pull/stash toolbar whose push/pull
/// results present as a log sheet. History: the paginated commit list with
/// incoming and unpushed markers.
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
    /// Which segment is showing (Changes | History).
    @State private var segment: SupermuxChangesSegment = .changes
    /// The completed push/pull whose log is presenting as a sheet.
    @State private var presentedSyncLog: SupermuxChangesSyncLogEntry?
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
                    if let store, store.hasLoaded, store.status?.isRepository != false {
                        SupermuxChangesSyncToolbar(
                            ahead: store.status?.ahead ?? 0,
                            behind: store.status?.behind ?? 0,
                            stashCount: store.status?.stashCount ?? 0,
                            isBusy: store.isMutating,
                            activeOperation: store.activeSyncOperation,
                            pull: {
                                Task {
                                    if let entry = await store.pull() { presentedSyncLog = entry }
                                }
                            },
                            push: {
                                Task {
                                    if let entry = await store.push() { presentedSyncLog = entry }
                                }
                            },
                            stash: { Task { await store.stash() } },
                            stashPop: { Task { await store.stashPop() } }
                        )
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
        .sheet(item: $presentedSyncLog) { entry in
            SupermuxSyncLogSheet(entry: entry)
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
                    loadedBody(store)
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

    /// The loaded-repository body: the Changes | History segmented control
    /// over the selected segment's list. The history `.task` is keyed on
    /// segment + ``SupermuxMobileChangesStore/historyEpoch`` so switching to
    /// History loads it lazily and a commit/push/pull-invalidated page
    /// reloads while visible.
    private func loadedBody(_ store: SupermuxMobileChangesStore) -> some View {
        VStack(spacing: 0) {
            segmentPicker
            switch segment {
            case .changes:
                changesList(store)
            case .history:
                historyList(store)
            }
        }
        .task(id: historyTaskKey(store)) {
            guard segment == .history else { return }
            await store.loadHistoryIfNeeded()
        }
    }

    /// `-1` off the History segment; the store's history epoch on it — any
    /// change re-fires the load task.
    private func historyTaskKey(_ store: SupermuxMobileChangesStore) -> Int {
        segment == .history ? store.historyEpoch : -1
    }

    private var segmentPicker: some View {
        Picker(selection: $segment) {
            Text(String(
                localized: "supermux.changes.segment.changes",
                defaultValue: "Changes",
                bundle: .module
            ))
            .tag(SupermuxChangesSegment.changes)
            Text(String(
                localized: "supermux.changes.segment.history",
                defaultValue: "History",
                bundle: .module
            ))
            .tag(SupermuxChangesSegment.history)
        } label: {
            Text(String(
                localized: "supermux.changes.segment.label",
                defaultValue: "Section",
                bundle: .module
            ))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier("SupermuxChangesSegmentPicker")
    }

    private func historyList(_ store: SupermuxMobileChangesStore) -> some View {
        SupermuxChangesHistoryList(
            incoming: SupermuxCommitRowSnapshot.rows(from: store.incomingCommits),
            commits: SupermuxCommitRowSnapshot.rows(from: store.historyCommits),
            hasLoaded: store.hasLoadedHistory,
            isLoading: store.isLoadingHistory,
            hasMore: store.historyNextCursor != nil,
            errorDescription: store.historyErrorDescription,
            loadMore: { let store = store; Task { await store.loadMoreHistory() } }
        )
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
            SupermuxCommitComposerSection(
                message: Binding(
                    get: { store.commitMessage },
                    set: { store.commitMessage = $0 }
                ),
                hasStagedFiles: !staged.isEmpty,
                hasChanges: !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty,
                isBusy: store.isMutating || store.isGeneratingMessage,
                isGenerating: store.isGeneratingMessage,
                committedShortSha: store.lastCommitShortSha,
                aiUnavailableNotice: store.aiUnavailableNotice,
                commit: { let store = store; Task { await store.commit() } },
                // Empty draft → Generate & Commit stages everything Mac-side
                // (desktop AI-commit parity), so pass stageAll: true.
                generateAndCommit: { let store = store; Task { await store.generateAndCommit(stageAll: true) } }
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

/// The changes screen's two segments.
enum SupermuxChangesSegment: Hashable {
    /// Working-tree changes + commit composer.
    case changes
    /// Paginated commit history.
    case history
}

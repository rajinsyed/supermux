public import Foundation
public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// Project detail: header (avatar, name, root path, default branch), the
/// project's worktrees (state-colored PR badges, open/create/remove flows —
/// capability-gated on `supermux.worktrees.v1`), and the open workspaces
/// nested under this project (§6 join — tapping one opens it through the same
/// navigation as the flat list's rows).
public struct SupermuxProjectDetailScreen: View {
    // Internal (not private): the run/presets/actions half of the screen
    // lives in SupermuxProjectDetailScreen+RunSections.swift.
    let row: SupermuxProjectRowSnapshot
    private let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    let selectWorkspace: @MainActor (_ workspaceID: String) -> Void
    private let makeWorktreesStore: @MainActor (_ projectID: String) -> SupermuxMobileWorktreesStore?
    // Internal (not private): the presets manager entry in
    // SupermuxProjectDetailScreen+RunSections.swift needs the editing seam.
    let editing: SupermuxProjectEditingActions?
    let presets: [SupermuxTerminalPresetDTO]
    /// Whether the host serves the presets read shape at all — gates the
    /// Presets section (launcher + manager entry) so a zero-preset host with
    /// the capability still reaches the manager, while a host without it
    /// shows no presets UI.
    let showsPresets: Bool
    let showsActions: Bool
    let runActions: SupermuxProjectRunActions?

    /// The screen-owned worktrees session for this project; `nil` while
    /// disconnected or when the host lacks `supermux.worktrees.v1` (the
    /// Worktrees section hides entirely). Created and run by `.task`, so its
    /// event stream is structured — cancelled when the screen disappears.
    @State private var worktreesStore: SupermuxMobileWorktreesStore?
    @State private var showingNewWorktreeSheet = false
    @State private var isPreparingNewWorktree = false
    @State private var newWorktreeErrorMessage: String?
    /// The row awaiting the FIRST (always-shown) destructive removal confirm.
    @State private var removalCandidate: SupermuxWorktreeRowSnapshot?
    /// Error surface for a failed worktree open.
    @State private var openErrorMessage: String?
    /// The fresh DTO the tapped Edit button seeded the editor with; `nil`
    /// while the editor is closed.
    @State private var editorProject: SupermuxProjectDTO?
    /// Error surface for an Edit tap whose session lookup failed (stale row
    /// after a disconnect) — never a silent no-op.
    @State private var editErrorMessage: String?
    /// Error surface for a failed preset launch.
    @State var presetErrorMessage: String?
    /// Error surface for a failed project action.
    @State var actionErrorMessage: String?
    /// The transient "fired on your Mac" confirmation for a command action;
    /// `nil` hides the toast. Bumping ``actionToastEpoch`` restarts the
    /// auto-dismiss timer.
    @State var actionToast: String?
    @State var actionToastEpoch = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) var openURL

    /// Creates the detail screen.
    /// - Parameters:
    ///   - row: The project's value snapshot. The pushing `NavigationLink`
    ///     re-evaluates it with the parent, so nested rows stay live.
    ///   - iconPNGData: Custom-icon fetch by project id (etag-cached).
    ///   - selectWorkspace: Opens a nested workspace by its UI row id.
    ///   - makeWorktreesStore: Builds this project's worktrees store against
    ///     the live session, or `nil` when unavailable (section hides).
    ///   - editing: The editor seam; `nil` hides the Edit affordance.
    ///   - presets: The global presets, launchable into this project's root.
    ///   - showsPresets: Whether the Presets section (launcher rows + the
    ///     manager entry) renders at all — `false` for a host without the
    ///     `supermux.presets.v1` read shape.
    ///   - showsActions: Whether the Actions section renders (host advertises
    ///     `supermux.actions.v1`).
    ///   - runActions: The run/launch/action seam; `nil` hides the Run,
    ///     Presets, and Actions sections entirely (no live session).
    public init(
        row: SupermuxProjectRowSnapshot,
        iconPNGData: @escaping @Sendable (_ projectID: String) async -> Data?,
        selectWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void = { _ in },
        makeWorktreesStore: @escaping @MainActor (_ projectID: String) -> SupermuxMobileWorktreesStore? = { _ in nil },
        editing: SupermuxProjectEditingActions? = nil,
        presets: [SupermuxTerminalPresetDTO] = [],
        showsPresets: Bool = false,
        showsActions: Bool = false,
        runActions: SupermuxProjectRunActions? = nil
    ) {
        self.row = row
        self.iconPNGData = iconPNGData
        self.selectWorkspace = selectWorkspace
        self.makeWorktreesStore = makeWorktreesStore
        self.editing = editing
        self.presets = presets
        self.showsPresets = showsPresets
        self.showsActions = showsActions
        self.runActions = runActions
    }

    public var body: some View {
        // Staged sub-expressions (`decoratedList` → here) keep each modifier
        // chain small enough for the type checker.
        decoratedList
            .toolbar {
            if let editing {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Seed from the freshest fetched DTO so the editor
                        // reflects fields the row snapshot doesn't carry
                        // (commands, actions, config marker).
                        if let project = editing.editorProject(row.id) {
                            editorProject = project
                        } else {
                            editErrorMessage = String(
                                localized: "supermux.editor.error.unavailable",
                                defaultValue: "Not connected to a Mac.",
                                bundle: .module
                            )
                        }
                    } label: {
                        Text(String(
                            localized: "supermux.projects.detail.edit",
                            defaultValue: "Edit",
                            bundle: .module
                        ))
                    }
                    .accessibilityIdentifier("SupermuxProjectDetailEditButton")
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { editorProject != nil },
                set: { if !$0 { editorProject = nil } }
            )
        ) {
            if let editorProject, let editing {
                SupermuxProjectEditorSheet(
                    mode: .edit(editorProject),
                    editing: editing,
                    onDeleted: { dismiss() }
                )
            }
        }
        .alert(
            String(
                localized: "supermux.projects.detail.edit.failed.title",
                defaultValue: "Couldn’t Edit Project",
                bundle: .module
            ),
            isPresented: Binding(
                get: { editErrorMessage != nil },
                set: { if !$0 { editErrorMessage = nil } }
            ),
            presenting: editErrorMessage
        ) { _ in
            Button(role: .cancel) {
                editErrorMessage = nil
            } label: {
                Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
            }
        } message: { message in
            Text(message)
        }
        .task(id: row.id) {
            let store = makeWorktreesStore(row.id)
            worktreesStore = store
            guard let store else { return }
            await store.run()
        }
        .sheet(isPresented: $showingNewWorktreeSheet) {
            if let store = worktreesStore {
                SupermuxNewWorktreeSheet(
                    projectName: row.name,
                    branches: store.branches,
                    defaultBaseBranch: row.defaultBranch,
                    showsBaseBranchPicker: store.supportsStartingBranchSelection,
                    suggestBranch: { workspaceName in
                        try await store.suggestBranchName(workspaceName: workspaceName).branchName
                    },
                    createWorktree: { workspaceName, branchName, baseBranch, open in
                        try await store.createWorktree(
                            workspaceName: workspaceName,
                            branchName: branchName,
                            baseBranch: baseBranch,
                            open: open
                        ).workspaceId
                    },
                    openWorkspace: selectWorkspace
                )
            }
        }
        .alert(
            String(
                localized: "supermux.newWorktree.title",
                defaultValue: "New Worktree",
                bundle: .module
            ),
            isPresented: Binding(
                get: { newWorktreeErrorMessage != nil },
                set: { if !$0 { newWorktreeErrorMessage = nil } }
            ),
            presenting: newWorktreeErrorMessage
        ) { _ in
            Button(role: .cancel) {
                newWorktreeErrorMessage = nil
            } label: {
                Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
            }
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            removalCandidate.map { candidate in
                String(
                    localized: "supermux.worktrees.remove.confirm.title",
                    defaultValue: "Remove worktree “\(candidate.displayName)”?",
                    bundle: .module
                )
            } ?? "",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: removalCandidate
        ) { candidate in
            Button(role: .destructive) {
                let store = worktreesStore
                Task { await store?.removeWorktree(path: candidate.path) }
            } label: {
                Text(String(
                    localized: "supermux.worktrees.remove.confirm.action",
                    defaultValue: "Remove",
                    bundle: .module
                ))
            }
        } message: { _ in
            Text(String(
                localized: "supermux.worktrees.remove.confirm.message",
                defaultValue: "This removes the worktree directory on your Mac.",
                bundle: .module
            ))
        }
        .alert(
            String(
                localized: "supermux.worktrees.remove.force.title",
                defaultValue: "Uncommitted Changes",
                bundle: .module
            ),
            isPresented: Binding(
                get: { forceConfirmation != nil },
                set: { if !$0 { worktreesStore?.dismissRemoval() } }
            ),
            presenting: forceConfirmation
        ) { confirmation in
            Button(role: .destructive) {
                let store = worktreesStore
                Task { await store?.removeWorktree(path: confirmation.path, force: true) }
            } label: {
                Text(String(
                    localized: "supermux.worktrees.remove.force.action",
                    defaultValue: "Remove Anyway",
                    bundle: .module
                ))
            }
            Button(role: .cancel) {
                worktreesStore?.dismissRemoval()
            } label: {
                Text(String(
                    localized: "supermux.common.cancel",
                    defaultValue: "Cancel",
                    bundle: .module
                ))
            }
        } message: { _ in
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
                get: { removalFailureMessage != nil },
                set: { if !$0 { worktreesStore?.dismissRemoval() } }
            ),
            presenting: removalFailureMessage
        ) { _ in
            Button(role: .cancel) {
                worktreesStore?.dismissRemoval()
            } label: {
                Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
            }
        } message: { message in
            Text(message)
        }
        .alert(
            String(
                localized: "supermux.worktrees.open.failed.title",
                defaultValue: "Couldn’t Open Worktree",
                bundle: .module
            ),
            isPresented: Binding(
                get: { openErrorMessage != nil },
                set: { if !$0 { openErrorMessage = nil } }
            ),
            presenting: openErrorMessage
        ) { _ in
            Button(role: .cancel) {
                openErrorMessage = nil
            } label: {
                Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
            }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Body stages

    /// The list plus its identity/toast/run-error dressing — split from
    /// ``body`` so each modifier chain stays type-checkable. The run-flow
    /// decorations (toast + launch/action alerts) live in
    /// SupermuxProjectDetailScreen+RunSections.swift.
    private var decoratedList: some View {
        runDecorated(
            listCore
                .navigationTitle(row.name)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .accessibilityIdentifier("SupermuxProjectDetail")
        )
    }

    /// The bare list content.
    private var listCore: some View {
        List {
            headerSection
            if let run = row.run, let runActions {
                runSection(run: run, runActions: runActions)
            }
            if let store = worktreesStore, store.showsWorktrees {
                SupermuxWorktreesSection(
                    hasLoaded: store.hasLoaded,
                    rows: SupermuxWorktreeRowSnapshot.rows(from: store.worktrees),
                    isPreparingNewWorktree: isPreparingNewWorktree,
                    newWorktree: prepareNewWorktree,
                    openWorktree: { openWorktree($0) },
                    requestRemoval: { removalCandidate = $0 }
                )
            }
            workspacesSection
            // Gated on the read shape, not on non-emptiness: a zero-preset
            // host still shows the manager entry (the section-level presets
            // row was removed — the detail screen is the presets surface).
            if showsPresets, runActions != nil {
                presetsSection
            }
            if showsActions, runActions != nil, !row.actions.isEmpty {
                actionsSection
            }
        }
    }

    // MARK: - Sections

    /// The identity card: a large accent avatar over the project's name, its
    /// path, and its default branch as a chip.
    ///
    /// This replaces a cramped 44pt avatar row followed by two `LabeledContent`
    /// rows that repeated the path immediately below it. Centering the identity
    /// and dropping the duplicate gives the screen an actual header instead of
    /// a list that starts mid-sentence.
    private var headerSection: some View {
        Section {
            VStack(spacing: 12) {
                SupermuxProjectAvatar(row: row, size: 68, iconPNGData: iconPNGData)
                    .shadow(color: row.accent.color.opacity(0.28), radius: 10, y: 4)
                VStack(spacing: 4) {
                    Text(row.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(row.rootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                if let defaultBranch = row.defaultBranch, !defaultBranch.isEmpty {
                    branchChip(defaultBranch)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
        }
    }

    /// The default-branch chip: the app's capsule-badge idiom, tinted by the
    /// project's accent so the header carries the project's identity color.
    private func branchChip(_ branch: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption2.weight(.semibold))
            Text(branch)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(row.accent.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(row.accent.color.opacity(0.14)))
        .accessibilityLabel(String(
            localized: "supermux.projects.detail.defaultBranchLabel",
            defaultValue: "Default Branch",
            bundle: .module
        ))
        .accessibilityValue(branch)
    }

    private var workspacesSection: some View {
        Section {
            if row.openWorkspaces.isEmpty {
                Text(String(
                    localized: "supermux.projects.detail.workspacesPlaceholder",
                    defaultValue: "Workspaces opened from this project will appear here.",
                    bundle: .module
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ForEach(row.openWorkspaces) { workspace in
                    SupermuxProjectWorkspaceRow(workspace: workspace, selectWorkspace: selectWorkspace)
                }
            }
        } header: {
            Text(String(
                localized: "supermux.projects.detail.workspacesTitle",
                defaultValue: "Workspaces",
                bundle: .module
            ))
        }
    }

    // MARK: - Worktree flows

    /// Fetches an authoritative branch snapshot immediately before presenting
    /// the create sheet. Branch-only git changes do not emit worktree events,
    /// so the detail screen's long-lived cache is intentionally not trusted.
    private func prepareNewWorktree() {
        guard let store = worktreesStore, !isPreparingNewWorktree else { return }
        isPreparingNewWorktree = true
        newWorktreeErrorMessage = nil
        Task {
            defer { isPreparingNewWorktree = false }
            do {
                try await store.refreshBranches()
                showingNewWorktreeSheet = true
            } catch {
                newWorktreeErrorMessage = error.localizedDescription
            }
        }
    }

    /// Open worktrees navigate straight to their workspace (same idiom as the
    /// nested workspace rows); unopened ones ask the Mac to open a workspace
    /// first, then navigate to the result.
    private func openWorktree(_ worktree: SupermuxWorktreeRowSnapshot) {
        if let workspaceID = worktree.workspaceID {
            selectWorkspace(workspaceID)
            return
        }
        guard let store = worktreesStore else { return }
        Task {
            do {
                if let workspaceID = try await store.openWorktree(path: worktree.path) {
                    selectWorkspace(workspaceID)
                }
            } catch {
                openErrorMessage = error.localizedDescription
            }
        }
    }

    /// The dirty-worktree confirm-force payload, when the store parked there.
    private var forceConfirmation: (path: String, message: String)? {
        guard case let .awaitingForceConfirmation(path, _, message) = worktreesStore?.removal else { return nil }
        return (path, message)
    }

    /// The removal-failure message: `.failed`, or `.confirmationStale`
    /// (aborted force-remove) via the same "Couldn't Remove Worktree" alert.
    private var removalFailureMessage: String? {
        switch worktreesStore?.removal {
        case let .failed(_, message): message
        case .confirmationStale:
            String(localized: "supermux.worktrees.remove.staleConfirmation", defaultValue: "This worktree changed since you confirmed — nothing was removed. Try again.", bundle: .module)
        default: nil
        }
    }
}

/// One open workspace nested under the project, laid out like the mac
/// sidebar's `SupermuxOpenWorkspaceRowView`: title with a monospaced branch
/// subtitle, then the trailing status cluster — agent activity, PR badge,
/// run indicator — plus the phone's unread dot and navigation chevron.
/// Tapping opens the workspace through the shell's own navigation closure.
struct SupermuxProjectWorkspaceRow: View {
    let workspace: SupermuxProjectWorkspaceRowSnapshot
    let selectWorkspace: @MainActor (_ workspaceID: String) -> Void

    var body: some View {
        Button {
            selectWorkspace(workspace.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let branch = workspace.branch {
                        Text(branch)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                // Status cluster on the trailing edge, mac order: activity,
                // PR badge, run indicator (idle activity renders nothing).
                SupermuxWorkspaceActivityDot(activity: workspace.activity)
                if let pullRequest = workspace.pullRequest {
                    SupermuxMobilePullRequestBadge(pullRequest: pullRequest)
                }
                if workspace.isRunning {
                    SupermuxMobileRunIndicator()
                }
                if workspace.hasUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.name)
        .accessibilityValue(workspace.activity.map(SupermuxWorkspaceActivityDot.label(for:)) ?? "")
        .accessibilityIdentifier("SupermuxProjectWorkspaceRow-\(workspace.id)")
    }
}

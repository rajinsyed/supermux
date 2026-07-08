public import Foundation
public import SupermuxMobileKit
public import SwiftUI

/// Project detail: header (avatar, name, root path, default branch), the
/// project's worktrees (state-colored PR badges, open/create/remove flows —
/// capability-gated on `supermux.worktrees.v1`), and the open workspaces
/// nested under this project (§6 join — tapping one opens it through the same
/// navigation as the flat list's rows).
public struct SupermuxProjectDetailScreen: View {
    private let row: SupermuxProjectRowSnapshot
    private let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    private let selectWorkspace: @MainActor (_ workspaceID: String) -> Void
    private let makeWorktreesStore: @MainActor (_ projectID: String) -> SupermuxMobileWorktreesStore?

    /// The screen-owned worktrees session for this project; `nil` while
    /// disconnected or when the host lacks `supermux.worktrees.v1` (the
    /// Worktrees section hides entirely). Created and run by `.task`, so its
    /// event stream is structured — cancelled when the screen disappears.
    @State private var worktreesStore: SupermuxMobileWorktreesStore?
    @State private var showingNewWorktreeSheet = false
    /// The row awaiting the FIRST (always-shown) destructive removal confirm.
    @State private var removalCandidate: SupermuxWorktreeRowSnapshot?
    /// Error surface for a failed worktree open.
    @State private var openErrorMessage: String?

    /// Creates the detail screen.
    /// - Parameters:
    ///   - row: The project's value snapshot. The pushing `NavigationLink`
    ///     re-evaluates it with the parent, so nested rows stay live.
    ///   - iconPNGData: Custom-icon fetch by project id (etag-cached).
    ///   - selectWorkspace: Opens a nested workspace by its UI row id.
    ///   - makeWorktreesStore: Builds this project's worktrees store against
    ///     the live session, or `nil` when unavailable (section hides).
    public init(
        row: SupermuxProjectRowSnapshot,
        iconPNGData: @escaping @Sendable (_ projectID: String) async -> Data?,
        selectWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void = { _ in },
        makeWorktreesStore: @escaping @MainActor (_ projectID: String) -> SupermuxMobileWorktreesStore? = { _ in nil }
    ) {
        self.row = row
        self.iconPNGData = iconPNGData
        self.selectWorkspace = selectWorkspace
        self.makeWorktreesStore = makeWorktreesStore
    }

    public var body: some View {
        List {
            headerSection
            if let store = worktreesStore, store.showsWorktrees {
                SupermuxWorktreesSection(
                    hasLoaded: store.hasLoaded,
                    rows: SupermuxWorktreeRowSnapshot.rows(from: store.worktrees),
                    newWorktree: { showingNewWorktreeSheet = true },
                    openWorktree: { openWorktree($0) },
                    requestRemoval: { removalCandidate = $0 }
                )
            }
            workspacesSection
        }
        .navigationTitle(row.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("SupermuxProjectDetail")
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
                    suggestBranch: { workspaceName in
                        try await store.suggestBranchName(workspaceName: workspaceName).branchName
                    },
                    createWorktree: { workspaceName, branchName, open in
                        try await store.createWorktree(
                            workspaceName: workspaceName,
                            branchName: branchName,
                            open: open
                        ).workspaceId
                    },
                    openWorkspace: selectWorkspace
                )
            }
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

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                SupermuxProjectMobileAvatar(row: row, size: 44, iconPNGData: iconPNGData)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.headline)
                    Text(row.rootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            LabeledContent(
                String(
                    localized: "supermux.projects.detail.pathLabel",
                    defaultValue: "Path",
                    bundle: .module
                ),
                value: row.rootPath
            )
            .font(.callout)
            if let defaultBranch = row.defaultBranch {
                LabeledContent(
                    String(
                        localized: "supermux.projects.detail.defaultBranchLabel",
                        defaultValue: "Default Branch",
                        bundle: .module
                    ),
                    value: defaultBranch
                )
                .font(.callout)
            }
        }
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
        guard case let .awaitingForceConfirmation(path, message) = worktreesStore?.removal else {
            return nil
        }
        return (path, message)
    }

    /// The terminal removal-failure message, when the store parked there.
    private var removalFailureMessage: String? {
        guard case let .failed(_, message) = worktreesStore?.removal else { return nil }
        return message
    }
}

/// One open workspace nested under the project: activity dot, name, unread
/// dot, and a disclosure chevron. Tapping opens the workspace through the
/// shell's own navigation closure.
struct SupermuxProjectWorkspaceRow: View {
    let workspace: SupermuxProjectWorkspaceRowSnapshot
    let selectWorkspace: @MainActor (_ workspaceID: String) -> Void

    var body: some View {
        Button {
            selectWorkspace(workspace.id)
        } label: {
            HStack(spacing: 8) {
                SupermuxWorkspaceActivityDot(activity: workspace.activity)
                Text(workspace.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
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

public import Foundation
public import SwiftUI

/// Read-only project detail: header (avatar, name, root path, default
/// branch), the open workspaces nested under this project (§6 join — tapping
/// one opens it through the same navigation as the flat list's rows), and a
/// placeholder section for the worktree list a later milestone fills in.
public struct SupermuxProjectDetailScreen: View {
    private let row: SupermuxProjectRowSnapshot
    private let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    private let selectWorkspace: @MainActor (_ workspaceID: String) -> Void

    /// Creates the detail screen.
    /// - Parameters:
    ///   - row: The project's value snapshot. The pushing `NavigationLink`
    ///     re-evaluates it with the parent, so nested rows stay live.
    ///   - iconPNGData: Custom-icon fetch by project id (etag-cached).
    ///   - selectWorkspace: Opens a nested workspace by its UI row id.
    public init(
        row: SupermuxProjectRowSnapshot,
        iconPNGData: @escaping @Sendable (_ projectID: String) async -> Data?,
        selectWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void = { _ in }
    ) {
        self.row = row
        self.iconPNGData = iconPNGData
        self.selectWorkspace = selectWorkspace
    }

    public var body: some View {
        List {
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
            Section {
                Text(String(
                    localized: "supermux.projects.detail.worktreesPlaceholder",
                    defaultValue: "Worktrees for this project will appear here.",
                    bundle: .module
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            } header: {
                Text(String(
                    localized: "supermux.projects.detail.worktreesTitle",
                    defaultValue: "Worktrees",
                    bundle: .module
                ))
            }
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
        .navigationTitle(row.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("SupermuxProjectDetail")
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

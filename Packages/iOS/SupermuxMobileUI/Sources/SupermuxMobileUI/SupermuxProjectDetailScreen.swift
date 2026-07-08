public import Foundation
public import SwiftUI

/// Read-only project detail: header (avatar, name, root path, default
/// branch) plus placeholder sections for the worktree and workspace lists
/// that later milestones fill in.
public struct SupermuxProjectDetailScreen: View {
    private let row: SupermuxProjectRowSnapshot
    private let iconPNGData: @Sendable (_ projectID: String) async -> Data?

    /// Creates the detail screen.
    /// - Parameters:
    ///   - row: The project's value snapshot, captured at push time.
    ///   - iconPNGData: Custom-icon fetch by project id (etag-cached).
    public init(
        row: SupermuxProjectRowSnapshot,
        iconPNGData: @escaping @Sendable (_ projectID: String) async -> Data?
    ) {
        self.row = row
        self.iconPNGData = iconPNGData
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
                Text(String(
                    localized: "supermux.projects.detail.workspacesPlaceholder",
                    defaultValue: "Workspaces opened from this project will appear here.",
                    bundle: .module
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
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

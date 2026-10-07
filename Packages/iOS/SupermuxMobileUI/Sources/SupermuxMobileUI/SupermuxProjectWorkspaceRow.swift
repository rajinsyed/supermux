import SwiftUI

/// One open workspace nested under the project, laid out like the mac
/// sidebar's `SupermuxOpenWorkspaceRowView`: title with a monospaced branch
/// subtitle, then the trailing status cluster — agent activity, run
/// indicator — plus the phone's unread dot and navigation chevron.
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
                // run indicator (idle activity renders nothing).
                // 9: this row titles in `.subheadline`, matching the sidebar's
                // nested rows rather than the shell tiles' headline scale.
                SupermuxWorkspaceActivityDot(activity: workspace.activity, size: 9)
                if workspace.isRunning {
                    SupermuxMobileRunIndicator()
                }
                if workspace.hasUnread {
                    // The same badge the workspace list draws. This was its own
                    // 8pt accent circle, which made the detail screen a third
                    // unread indicator alongside the Mac's and the list's.
                    SupermuxMobileUnreadBadge(count: workspace.unreadCount, fontSize: 10)
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

import SwiftUI

/// An unopened worktree of a project copy on another Mac, indented under the
/// project like a local worktree row, with the Mac's chip. Tapping opens it on
/// that Mac and focuses its mirror here.
struct SupermuxRemoteWorktreeRowView: View {
    let worktree: SupermuxRemoteWorktree
    let open: () -> Void
    /// Removes the worktree on its Mac; `true` also deletes the branch.
    let delete: (Bool) -> Void
    var openPullRequest: (URL) -> Void = { _ in }

    @Environment(\.supermuxSidebarFontScale) private var fontScale
    @State private var isHovered = false

    private var isOnline: Bool { worktree.location.isOnline }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8.5 * fontScale, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 20 * fontScale)
            Text(worktree.displayName)
                .font(.system(size: 11.5 * fontScale))
                .foregroundStyle(isHovered && isOnline ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if let device = worktree.location.device {
                SupermuxDeviceChip(device: device, fontScale: fontScale)
            }
            if let pullRequest = worktree.pullRequest {
                SupermuxPullRequestBadge(pullRequest: pullRequest, fontScale: fontScale, onOpen: openPullRequest)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 8.5 * fontScale, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovered && isOnline ? 1 : 0)
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(worktree.path)
        .onHover { isHovered = $0 }
        .onTapGesture { if isOnline { open() } }
        .contextMenu {
            Button(String(localized: "supermux.worktree.open", defaultValue: "Open Workspace"), action: open)
                .disabled(!isOnline)
            Divider()
            Button(String(localized: "supermux.worktree.delete", defaultValue: "Delete Worktree"), role: .destructive) {
                delete(false)
            }
            .disabled(!isOnline)
            Button(String(localized: "supermux.worktree.deleteWithBranch", defaultValue: "Delete Worktree and Branch"), role: .destructive) {
                delete(true)
            }
            .disabled(!isOnline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(worktree.displayName)
        .accessibilityAddTraits(.isButton)
    }
}

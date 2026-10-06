import SwiftUI

/// A project that exists only on another Mac: the header (avatar, name, the
/// Mac's chip, run indicator), its mirrored workspaces nested under it, and —
/// when expanded — that Mac's unopened worktrees. Tapping the header opens the
/// project on that Mac and focuses the mirror here.
struct SupermuxRemoteProjectRowView: View {
    let row: SupermuxRemoteProjectRow
    /// Local mirrors of that Mac's workspaces owned by this project.
    let openWorkspaces: [SupermuxOpenWorkspace]
    let isExpanded: Bool
    let actions: SupermuxRemoteProjectActions
    let toggleExpanded: () -> Void
    let newWorktree: () -> Void
    let setUp: (SupermuxProjectSetupDestination) -> Void
    let selectWorkspace: (UUID) -> Void
    let closeWorkspace: (UUID) -> Void
    let renameWorkspace: (UUID) -> Void
    let openPullRequest: (URL, UUID?) -> Void
    /// Worktrees being created here in the background.
    var pendingWorktrees: [SupermuxPendingWorktreeRow] = []
    var pendingActions: SupermuxPendingWorktreeActions = .inert

    @Environment(\.supermuxSidebarFontScale) private var fontScale
    @State private var isHovered = false

    private var isOnline: Bool { row.location.isOnline }
    private var deviceName: String { row.location.device?.name ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            ForEach(openWorkspaces) { workspace in
                SupermuxOpenWorkspaceRowView(
                    workspace: workspace,
                    select: { selectWorkspace(workspace.id) },
                    close: { closeWorkspace(workspace.id) },
                    hide: { actions.hideMirror(workspace.id) },
                    rename: { renameWorkspace(workspace.id) },
                    draggingWorkspaceId: .constant(nil),
                    openPullRequest: { url in openPullRequest(url, workspace.id) },
                    mirrorMenu: { actions.mirrorMenu(workspace.id) }
                )
                .equatable()
            }
            ForEach(pendingWorktrees) { pending in
                SupermuxPendingWorktreeRowView(row: pending, actions: pendingActions)
                    .equatable()
            }
            if isExpanded {
                ForEach(row.worktrees) { worktree in
                    SupermuxRemoteWorktreeRowView(
                        worktree: worktree,
                        open: { actions.openWorktree(worktree) },
                        delete: { deleteBranch in actions.removeWorktree(worktree, deleteBranch) },
                        openPullRequest: { url in openPullRequest(url, nil) }
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: 7) {
            SupermuxProjectAvatarView(project: row.avatar, detectedIcon: row.icon, size: 20 * fontScale)
            Text(row.project.name)
                .font(.system(size: 12 * fontScale, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                // Shares the width with the Mac's chip (see SupermuxDeviceChip).
                .layoutPriority(1)
            if let device = row.location.device {
                SupermuxDeviceChip(device: device, fontScale: fontScale)
            }
            Spacer(minLength: 2)
            if row.isRunning {
                SupermuxRunIndicator()
            }
            let disclosure = SupermuxWorktreeDisclosure(remoteOnly: row)
            if disclosure.isShown {
                expandToggle(count: disclosure.count)
            }
            if isHovered && isOnline {
                SupermuxSidebarIconButton(
                    systemName: "plus",
                    help: String(localized: "supermux.project.newWorktree", defaultValue: "New Worktree…"),
                    fontScale: fontScale,
                    action: newWorktree
                )
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        .opacity(isOnline ? 1 : 0.55)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { if isOnline { actions.openProject(row.location) } }
        .contextMenu { menu }
        .help(isOnline
            ? row.location.rootPath
            : String(localized: "supermux.devices.projectOffline", defaultValue: "\(deviceName) is offline"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.project.name)
        .accessibilityAddTraits(.isButton)
    }

    /// The "⑂ N ›" worktree disclosure, shown only while that Mac has an
    /// unopened worktree of the project (see ``SupermuxWorktreeDisclosure``).
    private func expandToggle(count: Int) -> some View {
        Button(action: toggleExpanded) {
            HStack(spacing: 3 * fontScale) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8 * fontScale, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9.5 * fontScale, weight: .semibold).monospacedDigit())
                Image(systemName: "chevron.right")
                    .font(.system(size: 6.5 * fontScale, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(isExpanded ? Color.primary : Color.secondary)
            .padding(.horizontal, 6 * fontScale)
            .frame(height: 18 * fontScale)
            .background(Capsule().fill(Color.primary.opacity(isExpanded ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(SupermuxPressEffectButtonStyle())
        .help(String(localized: "supermux.project.worktrees.help", defaultValue: "Open another worktree"))
    }

    @ViewBuilder
    private var menu: some View {
        Button(String(localized: "supermux.remoteProject.openOn", defaultValue: "Open on \(deviceName)")) {
            actions.openProject(row.location)
        }
        .disabled(!isOnline)
        Button(String(localized: "supermux.project.newWorktree", defaultValue: "New Worktree…"), action: newWorktree)
            .disabled(!isOnline)
        if !row.worktrees.isEmpty {
            Menu(String(localized: "supermux.project.worktreesMenu", defaultValue: "Worktrees")) {
                SupermuxRemoteWorktreeMenuItems(worktrees: row.worktrees, actions: actions)
            }
        }
        if !row.actions.isEmpty {
            Menu(String(localized: "supermux.project.actionsMenu", defaultValue: "Actions")) {
                ForEach(row.actions, id: \.id) { action in
                    Button { actions.runAction(row.location, action) } label: {
                        Label(action.name, systemImage: action.iconSymbol ?? "bolt")
                    }
                }
            }
            .disabled(!isOnline)
        }
        if !row.setUpTargets.isEmpty {
            Divider()
            ForEach(row.setUpTargets, id: \.self) { destination in
                Button(String(localized: "supermux.project.setUpOn", defaultValue: "Set Up on \(destination.name)…")) {
                    setUp(destination)
                }
            }
        }
        Divider()
        Button(
            String(localized: "supermux.remoteProject.remove", defaultValue: "Remove from Projects on \(deviceName)…"),
            role: .destructive
        ) {
            actions.removeProject(row.location, row.project.name)
        }
        .disabled(!isOnline)
    }
}

/// "Worktrees ▸" menu entries for remote worktrees: each opens a submenu
/// with Open and the two deletes, labeled with its Mac.
struct SupermuxRemoteWorktreeMenuItems: View {
    let worktrees: [SupermuxRemoteWorktree]
    let actions: SupermuxRemoteProjectActions

    var body: some View {
        ForEach(worktrees) { worktree in
            Menu("\(worktree.displayName) — \(worktree.location.device?.name ?? "")") {
                Button(String(localized: "supermux.worktree.open", defaultValue: "Open Workspace")) {
                    actions.openWorktree(worktree)
                }
                Divider()
                Button(String(localized: "supermux.worktree.delete", defaultValue: "Delete Worktree"), role: .destructive) {
                    actions.removeWorktree(worktree, false)
                }
                Button(
                    String(localized: "supermux.worktree.deleteWithBranch", defaultValue: "Delete Worktree and Branch"),
                    role: .destructive
                ) {
                    actions.removeWorktree(worktree, true)
                }
            }
            .disabled(!worktree.location.isOnline)
        }
    }
}

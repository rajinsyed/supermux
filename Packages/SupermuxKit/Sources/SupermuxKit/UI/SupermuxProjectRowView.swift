public import SwiftUI
public import AppKit

/// Callbacks a project row needs from its host section.
public struct SupermuxProjectRowActions {
    /// Opens the project root as a workspace.
    public var openLocal: () -> Void
    /// Starts the "new worktree" flow.
    public var newWorktree: () -> Void
    /// Opens an existing worktree as a workspace.
    public var openWorktree: (SupermuxProjectWorktree) -> Void
    /// Deletes a worktree; the Bool requests local-branch deletion too.
    public var deleteWorktree: (SupermuxProjectWorktree, Bool) -> Void
    /// Toggles the worktree disclosure.
    public var toggleExpanded: () -> Void
    /// Opens the project editor sheet.
    public var edit: () -> Void
    /// Unregisters the project.
    public var remove: () -> Void
    /// Reveals the project root in Finder.
    public var revealInFinder: () -> Void
    /// Launches a project action in a fresh workspace.
    public var launchAction: (SupermuxProjectAction) -> Void
    /// Focuses a nested open workspace by id.
    public var selectWorkspace: (UUID) -> Void
    /// Closes a nested open workspace by id.
    public var closeWorkspace: (UUID) -> Void

    /// Memberwise initializer (all callbacks required).
    public init(
        openLocal: @escaping () -> Void,
        newWorktree: @escaping () -> Void,
        openWorktree: @escaping (SupermuxProjectWorktree) -> Void,
        deleteWorktree: @escaping (SupermuxProjectWorktree, Bool) -> Void,
        toggleExpanded: @escaping () -> Void,
        edit: @escaping () -> Void,
        remove: @escaping () -> Void,
        revealInFinder: @escaping () -> Void,
        launchAction: @escaping (SupermuxProjectAction) -> Void,
        selectWorkspace: @escaping (UUID) -> Void,
        closeWorkspace: @escaping (UUID) -> Void
    ) {
        self.openLocal = openLocal
        self.newWorktree = newWorktree
        self.openWorktree = openWorktree
        self.deleteWorktree = deleteWorktree
        self.toggleExpanded = toggleExpanded
        self.edit = edit
        self.remove = remove
        self.revealInFinder = revealInFinder
        self.launchAction = launchAction
        self.selectWorkspace = selectWorkspace
        self.closeWorkspace = closeWorkspace
    }
}

/// One project in the sidebar Projects section, with an optional indented
/// list of its worktrees when expanded.
public struct SupermuxProjectRowView: View {
    private let project: SupermuxProject
    private let detectedIcon: NSImage?
    private let worktrees: [SupermuxProjectWorktree]
    private let openWorkspaces: [SupermuxOpenWorkspace]
    private let isExpanded: Bool
    private let actions: SupermuxProjectRowActions

    @State private var isHovered = false

    /// Creates a row.
    /// - Parameters:
    ///   - project: Project to render.
    ///   - detectedIcon: Logo auto-detected from the project files, passed as an
    ///     immutable value snapshot (the row holds no icon store).
    ///   - worktrees: Discovered worktrees for the project.
    ///   - openWorkspaces: Live workspaces belonging to this project, shown
    ///     nested under it.
    ///   - isExpanded: Whether the additional-worktree disclosure is open.
    ///   - actions: Host callbacks.
    public init(
        project: SupermuxProject,
        detectedIcon: NSImage? = nil,
        worktrees: [SupermuxProjectWorktree],
        openWorkspaces: [SupermuxOpenWorkspace] = [],
        isExpanded: Bool,
        actions: SupermuxProjectRowActions
    ) {
        self.project = project
        self.detectedIcon = detectedIcon
        self.worktrees = worktrees
        self.openWorkspaces = openWorkspaces
        self.isExpanded = isExpanded
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            projectRow
            // Live workspaces for this project are always nested under it
            // (piggycode-style); selecting one focuses it.
            ForEach(openWorkspaces) { workspace in
                SupermuxOpenWorkspaceRowView(
                    workspace: workspace,
                    select: { actions.selectWorkspace(workspace.id) },
                    close: { actions.closeWorkspace(workspace.id) }
                )
            }
            // The disclosure reveals worktrees that exist on disk but have no
            // open workspace yet, as one-tap "open" affordances.
            if isExpanded {
                ForEach(unopenedWorktrees) { worktree in
                    worktreeRow(worktree)
                }
            }
        }
    }

    /// Worktrees on disk that do not already have an open workspace, so the
    /// disclosure never duplicates a nested workspace row.
    private var unopenedWorktrees: [SupermuxProjectWorktree] {
        let openDirs = Set(openWorkspaces.map { ($0.directory as NSString).standardizingPath })
        return worktrees.filter { !openDirs.contains(($0.path as NSString).standardizingPath) }
    }

    private var projectRow: some View {
        HStack(spacing: 7) {
            SupermuxProjectAvatarView(project: project, detectedIcon: detectedIcon, size: 20)
            Text(project.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if !unopenedWorktrees.isEmpty {
                Button(action: actions.toggleExpanded) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("\(unopenedWorktrees.count)")
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(isHovered ? 0.14 : 0.08))
                    )
                }
                .buttonStyle(.plain)
                .help(String(localized: "supermux.project.worktrees.help", defaultValue: "Open another worktree"))
            }
            if isHovered {
                Button(action: actions.newWorktree) {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "supermux.project.newWorktree", defaultValue: "New Worktree…"))
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
        .onHover { isHovered = $0 }
        .onTapGesture(perform: actions.openLocal)
        .contextMenu { projectMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(project.name)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var projectMenu: some View {
        Button(String(localized: "supermux.project.openLocal", defaultValue: "Open Local Workspace"), action: actions.openLocal)
        Button(String(localized: "supermux.project.newWorktree", defaultValue: "New Worktree…"), action: actions.newWorktree)
        if !worktrees.isEmpty {
            Menu(String(localized: "supermux.project.worktreesMenu", defaultValue: "Worktrees")) {
                ForEach(worktrees) { worktree in
                    Button(worktree.displayName) { actions.openWorktree(worktree) }
                }
            }
        }
        if !project.actions.isEmpty {
            Menu(String(localized: "supermux.project.actionsMenu", defaultValue: "Actions")) {
                ForEach(project.actions) { action in
                    if action.isLaunchable {
                        Button { actions.launchAction(action) } label: {
                            Label(action.name, systemImage: action.resolvedIconSymbol)
                        }
                    }
                }
            }
        }
        Divider()
        Button(String(localized: "supermux.project.revealInFinder", defaultValue: "Reveal in Finder"), action: actions.revealInFinder)
        Button(String(localized: "supermux.project.edit", defaultValue: "Edit Project…"), action: actions.edit)
        Divider()
        Button(String(localized: "supermux.project.remove", defaultValue: "Remove from Projects"), role: .destructive, action: actions.remove)
    }

    private func worktreeRow(_ worktree: SupermuxProjectWorktree) -> some View {
        SupermuxWorktreeRowView(
            worktree: worktree,
            open: { actions.openWorktree(worktree) },
            delete: { deleteBranch in actions.deleteWorktree(worktree, deleteBranch) }
        )
    }
}

/// An indented worktree row under an expanded project.
struct SupermuxWorktreeRowView: View {
    let worktree: SupermuxProjectWorktree
    let open: () -> Void
    let delete: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(worktree.displayName)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
        }
        .padding(.leading, 24)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button(String(localized: "supermux.worktree.open", defaultValue: "Open Workspace"), action: open)
            Divider()
            if worktree.isSupermuxManaged {
                Button(String(localized: "supermux.worktree.delete", defaultValue: "Delete Worktree"), role: .destructive) {
                    delete(false)
                }
                Button(String(localized: "supermux.worktree.deleteWithBranch", defaultValue: "Delete Worktree and Branch"), role: .destructive) {
                    delete(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(worktree.displayName)
        .accessibilityAddTraits(.isButton)
    }
}

/// An indented live-workspace row nested under its project: selectable, with a
/// selection highlight and a hover close button.
struct SupermuxOpenWorkspaceRowView: View {
    let workspace: SupermuxOpenWorkspace
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(workspace.isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(workspace.title)
                    .font(.system(size: 11.5, weight: workspace.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let branch = workspace.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 2)
            if isHovered {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "supermux.workspace.close", defaultValue: "Close Workspace"))
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(workspace.isSelected
                    ? Color.accentColor.opacity(0.16)
                    : Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
        .contextMenu {
            Button(String(localized: "supermux.workspace.select", defaultValue: "Focus Workspace"), action: select)
            Divider()
            Button(String(localized: "supermux.workspace.close", defaultValue: "Close Workspace"), role: .destructive, action: close)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workspace.title)
        .accessibilityAddTraits(workspace.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

public import SwiftUI

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

    /// Memberwise initializer (all callbacks required).
    public init(
        openLocal: @escaping () -> Void,
        newWorktree: @escaping () -> Void,
        openWorktree: @escaping (SupermuxProjectWorktree) -> Void,
        deleteWorktree: @escaping (SupermuxProjectWorktree, Bool) -> Void,
        toggleExpanded: @escaping () -> Void,
        edit: @escaping () -> Void,
        remove: @escaping () -> Void,
        revealInFinder: @escaping () -> Void
    ) {
        self.openLocal = openLocal
        self.newWorktree = newWorktree
        self.openWorktree = openWorktree
        self.deleteWorktree = deleteWorktree
        self.toggleExpanded = toggleExpanded
        self.edit = edit
        self.remove = remove
        self.revealInFinder = revealInFinder
    }
}

/// One project in the sidebar Projects section, with an optional indented
/// list of its worktrees when expanded.
public struct SupermuxProjectRowView: View {
    private let project: SupermuxProject
    private let worktrees: [SupermuxProjectWorktree]
    private let isExpanded: Bool
    private let actions: SupermuxProjectRowActions

    @State private var isHovered = false

    /// Creates a row.
    /// - Parameters:
    ///   - project: Project to render.
    ///   - worktrees: Discovered worktrees for the project.
    ///   - isExpanded: Whether the worktree list is disclosed.
    ///   - actions: Host callbacks.
    public init(
        project: SupermuxProject,
        worktrees: [SupermuxProjectWorktree],
        isExpanded: Bool,
        actions: SupermuxProjectRowActions
    ) {
        self.project = project
        self.worktrees = worktrees
        self.isExpanded = isExpanded
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            projectRow
            if isExpanded {
                ForEach(worktrees) { worktree in
                    worktreeRow(worktree)
                }
            }
        }
    }

    private var projectRow: some View {
        HStack(spacing: 7) {
            SupermuxProjectAvatarView(project: project, size: 20)
            Text(project.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if !worktrees.isEmpty {
                Button(action: actions.toggleExpanded) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("\(worktrees.count)")
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
                .help(String(localized: "supermux.project.worktrees.help", defaultValue: "Show worktrees"))
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

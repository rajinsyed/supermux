public import SwiftUI
public import AppKit
import UniformTypeIdentifiers

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
    /// Moves the project one slot up in sidebar order (no-op when first).
    public var moveUp: () -> Void
    /// Moves the project one slot down in sidebar order (no-op when last).
    public var moveDown: () -> Void
    /// Reorders a nested workspace `(draggedId, targetId)` within this project.
    public var reorderWorkspace: (UUID, UUID) -> Void
    /// Opens a pull request's URL (from a worktree or workspace PR badge).
    public var openPullRequest: (URL) -> Void

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
        closeWorkspace: @escaping (UUID) -> Void,
        moveUp: @escaping () -> Void = {},
        moveDown: @escaping () -> Void = {},
        reorderWorkspace: @escaping (UUID, UUID) -> Void = { _, _ in },
        openPullRequest: @escaping (URL) -> Void = { _ in }
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
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.reorderWorkspace = reorderWorkspace
        self.openPullRequest = openPullRequest
    }
}

/// Live drag-reorder for project rows. As the dragged row hovers over another
/// project, `move` shuffles the model so the list previews the new order; the
/// drop simply clears the dragging marker. Holds only a binding to the host's
/// drag state plus a value closure, so it respects the sidebar snapshot rule.
public struct SupermuxProjectDropDelegate: DropDelegate {
    let targetProjectId: UUID
    @Binding var draggingProjectId: UUID?
    /// `(draggedId, targetId)` — reorders the dragged project over the target.
    let move: (UUID, UUID) -> Void

    /// Creates the reorder drop delegate for one target row.
    /// - Parameters:
    ///   - targetProjectId: The project this row represents.
    ///   - draggingProjectId: Shared binding to the in-flight drag, if any.
    ///   - move: Reorders `(draggedId, targetId)` in the model.
    public init(
        targetProjectId: UUID,
        draggingProjectId: Binding<UUID?>,
        move: @escaping (UUID, UUID) -> Void
    ) {
        self.targetProjectId = targetProjectId
        self._draggingProjectId = draggingProjectId
        self.move = move
    }

    public func dropEntered(info: DropInfo) {
        guard let dragged = draggingProjectId, dragged != targetProjectId else { return }
        move(dragged, targetProjectId)
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    public func performDrop(info: DropInfo) -> Bool {
        draggingProjectId = nil
        return true
    }
}

/// Applies the reorder drop target only when a delegate is supplied, so rows
/// rendered without drag wiring (previews, tests) stay inert.
private struct SupermuxProjectReorderDrop: ViewModifier {
    let delegate: SupermuxProjectDropDelegate?

    func body(content: Content) -> some View {
        if let delegate {
            content.onDrop(of: [.plainText, .text], delegate: delegate)
        } else {
            content
        }
    }
}

/// One project in the sidebar Projects section, with an optional indented
/// list of its worktrees when expanded.
public struct SupermuxProjectRowView: View {
    private let project: SupermuxProject
    private let detectedIcon: NSImage?
    private let worktrees: [SupermuxProjectWorktree]
    /// Resolved pull requests for this project's unopened worktrees, keyed by
    /// worktree path. An immutable value snapshot (the row holds no PR store), so
    /// a PR change in one project never invalidates another project's row.
    private let worktreePullRequests: [String: SupermuxPullRequest]
    private let openWorkspaces: [SupermuxOpenWorkspace]
    private let isExpanded: Bool
    private let actions: SupermuxProjectRowActions
    /// Shared marker for the project being dragged for reorder. Read here (not
    /// in the parent section's `ForEach`) so a drag-start write re-renders only
    /// this row's opacity in place — re-running the section's `ForEach` would
    /// recreate the row and cancel the in-flight drag (cmux `SidebarDragState`).
    @Binding private var draggingProjectId: UUID?
    /// Whether the project can move further up/down (for menu enablement).
    private let canMoveUp: Bool
    private let canMoveDown: Bool
    /// Starts a drag session, returning the reorder payload.
    private let beginDrag: () -> NSItemProvider
    /// Receives drops from sibling rows to reorder this project.
    private let dropDelegate: SupermuxProjectDropDelegate?
    /// Shared marker for the nested workspace being dragged for reorder. Passed
    /// straight to the child rows (which read it) — never read in this row's
    /// body, so a workspace-drag-start does not re-run the nested `ForEach`.
    @Binding private var draggingWorkspaceId: UUID?

    /// Sidebar font scale (cmux's `sidebar-font-size`); `1` at the default size.
    /// Multiplies the row's text and avatar so projects track the same setting
    /// as the flat workspace list.
    @Environment(\.supermuxSidebarFontScale) private var fontScale

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
    ///   - canMoveUp: Whether a Move Up action applies (not already first).
    ///   - canMoveDown: Whether a Move Down action applies (not already last).
    ///   - beginDrag: Starts a drag, returning the reorder payload.
    ///   - dropDelegate: Handles reorder drops from sibling rows.
    ///   - draggingProjectId: Shared marker for the project being dragged (read
    ///     here for the row dim; defaults to a constant `nil` for previews).
    ///   - draggingWorkspaceId: Shared marker for the nested workspace being
    ///     dragged for reorder (defaults to a constant `nil` for previews).
    public init(
        project: SupermuxProject,
        detectedIcon: NSImage? = nil,
        worktrees: [SupermuxProjectWorktree],
        worktreePullRequests: [String: SupermuxPullRequest] = [:],
        openWorkspaces: [SupermuxOpenWorkspace] = [],
        isExpanded: Bool,
        actions: SupermuxProjectRowActions,
        canMoveUp: Bool = false,
        canMoveDown: Bool = false,
        beginDrag: @escaping () -> NSItemProvider = { NSItemProvider() },
        dropDelegate: SupermuxProjectDropDelegate? = nil,
        draggingProjectId: Binding<UUID?> = .constant(nil),
        draggingWorkspaceId: Binding<UUID?> = .constant(nil)
    ) {
        self.project = project
        self.detectedIcon = detectedIcon
        self.worktrees = worktrees
        self.worktreePullRequests = worktreePullRequests
        self.openWorkspaces = openWorkspaces
        self.isExpanded = isExpanded
        self.actions = actions
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.beginDrag = beginDrag
        self.dropDelegate = dropDelegate
        self._draggingProjectId = draggingProjectId
        self._draggingWorkspaceId = draggingWorkspaceId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            projectRow
            // Live workspaces for this project are always nested under it
            // (piggycode-style); selecting one focuses it, and they can be
            // dragged to reorder within this project.
            let siblingIds = Set(openWorkspaces.map(\.id))
            ForEach(openWorkspaces) { workspace in
                SupermuxOpenWorkspaceRowView(
                    workspace: workspace,
                    select: { actions.selectWorkspace(workspace.id) },
                    close: { actions.closeWorkspace(workspace.id) },
                    beginDrag: {
                        draggingWorkspaceId = workspace.id
                        return NSItemProvider(object: workspace.id.uuidString as NSString)
                    },
                    dropDelegate: SupermuxWorkspaceDropDelegate(
                        targetWorkspaceId: workspace.id,
                        siblingWorkspaceIds: siblingIds,
                        draggingWorkspaceId: $draggingWorkspaceId,
                        reorder: actions.reorderWorkspace
                    ),
                    draggingWorkspaceId: $draggingWorkspaceId,
                    openPullRequest: actions.openPullRequest
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
            SupermuxProjectAvatarView(project: project, detectedIcon: detectedIcon, size: 20 * fontScale)
            Text(project.name)
                .font(.system(size: 12 * fontScale, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if !unopenedWorktrees.isEmpty {
                Button(action: actions.toggleExpanded) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8.5 * fontScale, weight: .semibold))
                        Text("\(unopenedWorktrees.count)")
                            .font(.system(size: 9.5 * fontScale, weight: .semibold).monospacedDigit())
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7 * fontScale, weight: .bold))
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
                        .font(.system(size: 10 * fontScale, weight: .semibold))
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
        .opacity(draggingProjectId == project.id ? 0.4 : 1)
        .onDrag(beginDrag)
        .modifier(SupermuxProjectReorderDrop(delegate: dropDelegate))
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
        if canMoveUp || canMoveDown {
            Divider()
            Button(String(localized: "supermux.project.moveUp", defaultValue: "Move Up"), action: actions.moveUp)
                .disabled(!canMoveUp)
            Button(String(localized: "supermux.project.moveDown", defaultValue: "Move Down"), action: actions.moveDown)
                .disabled(!canMoveDown)
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
            pullRequest: worktreePullRequests[worktree.path],
            open: { actions.openWorktree(worktree) },
            delete: { deleteBranch in actions.deleteWorktree(worktree, deleteBranch) },
            openPullRequest: actions.openPullRequest
        )
    }
}

/// An indented worktree row under an expanded project.
struct SupermuxWorktreeRowView: View {
    let worktree: SupermuxProjectWorktree
    /// The worktree branch's pull request, if one was probed; renders a badge.
    var pullRequest: SupermuxPullRequest?
    let open: () -> Void
    let delete: (Bool) -> Void
    /// Opens the PR badge's URL.
    var openPullRequest: (URL) -> Void = { _ in }

    @Environment(\.supermuxSidebarFontScale) private var fontScale
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9 * fontScale, weight: .medium))
                .foregroundStyle(.secondary)
            Text(worktree.displayName)
                .font(.system(size: 11.5 * fontScale))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if let pullRequest {
                SupermuxPullRequestBadge(
                    pullRequest: pullRequest,
                    fontScale: fontScale,
                    onOpen: openPullRequest
                )
            }
        }
        .padding(.leading, 24 * fontScale)
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
    /// Starts a drag session, returning the reorder payload.
    var beginDrag: () -> NSItemProvider = { NSItemProvider() }
    /// Accepts reorder drops from sibling workspace rows, if wired.
    var dropDelegate: SupermuxWorkspaceDropDelegate?
    /// Shared marker for the workspace being dragged. Read here (a leaf) so a
    /// drag-start write dims only this row in place; reading it in the parent
    /// `ForEach` would recreate the row and cancel the drag.
    @Binding var draggingWorkspaceId: UUID?
    /// Opens the workspace's PR badge URL (cmux's per-workspace PR state).
    var openPullRequest: (URL) -> Void = { _ in }

    @Environment(\.supermuxSidebarFontScale) private var fontScale
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Agent activity fills the leading slot when present (spinner /
            // pulsing / ready dot); idle workspaces show nothing — selection is
            // conveyed by the row highlight and bold title. The slot stays
            // fixed-width so titles align whether or not a dot is shown.
            ZStack {
                if workspace.activity.isVisible {
                    SupermuxAgentActivityIndicator(activity: workspace.activity, size: 6 * fontScale)
                }
            }
            .frame(width: 12 * fontScale, height: 12 * fontScale)
            VStack(alignment: .leading, spacing: 0) {
                Text(workspace.title)
                    .font(.system(size: 11.5 * fontScale, weight: workspace.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let branch = workspace.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 9.5 * fontScale, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 2)
            if let pullRequest = workspace.pullRequest {
                SupermuxPullRequestBadge(
                    pullRequest: pullRequest,
                    fontScale: fontScale,
                    onOpen: openPullRequest
                )
            }
            if workspace.isRunning {
                SupermuxRunIndicator()
            }
            if isHovered {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5 * fontScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "supermux.workspace.close", defaultValue: "Close Workspace"))
            }
        }
        .padding(.leading, 22 * fontScale)
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
        .opacity(draggingWorkspaceId == workspace.id ? 0.4 : 1)
        .onDrag(beginDrag)
        .modifier(SupermuxWorkspaceReorderDrop(delegate: dropDelegate))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workspace.title)
        .accessibilityAddTraits(workspace.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Drop delegate for reordering live workspace rows within one project.
///
/// Reorders **live** as the dragged row hovers over a sibling (like the project
/// rows), so the list animates smoothly under the cursor instead of snapping
/// only on release. Because the nested `ForEach` is keyed by stable workspace
/// ids, each live reorder animates as a move and the in-flight drag survives.
/// Drops are accepted only from sibling workspaces in the same project so a row
/// never jumps projects. Holds only ids, a binding to the host's drag state,
/// and a value closure, so it respects the sidebar snapshot rule.
public struct SupermuxWorkspaceDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID
    let siblingWorkspaceIds: Set<UUID>
    @Binding var draggingWorkspaceId: UUID?
    /// `(draggedId, targetId)` — reorders the dragged workspace over the target.
    let reorder: (UUID, UUID) -> Void

    /// Creates the reorder drop delegate for one target workspace row.
    /// - Parameters:
    ///   - targetWorkspaceId: The workspace this row represents.
    ///   - siblingWorkspaceIds: Workspaces nested under the same project.
    ///   - draggingWorkspaceId: Shared binding to the in-flight drag, if any.
    ///   - reorder: Reorders `(draggedId, targetId)` in the host's tab order.
    public init(
        targetWorkspaceId: UUID,
        siblingWorkspaceIds: Set<UUID>,
        draggingWorkspaceId: Binding<UUID?>,
        reorder: @escaping (UUID, UUID) -> Void
    ) {
        self.targetWorkspaceId = targetWorkspaceId
        self.siblingWorkspaceIds = siblingWorkspaceIds
        self._draggingWorkspaceId = draggingWorkspaceId
        self.reorder = reorder
    }

    /// Whether the in-flight drag is a reorderable sibling (not this row).
    private var acceptsDrop: Bool {
        guard let dragged = draggingWorkspaceId else { return false }
        return dragged != targetWorkspaceId && siblingWorkspaceIds.contains(dragged)
    }

    public func dropEntered(info: DropInfo) {
        guard let dragged = draggingWorkspaceId, acceptsDrop else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            reorder(dragged, targetWorkspaceId)
        }
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: acceptsDrop ? .move : .forbidden)
    }

    public func performDrop(info: DropInfo) -> Bool {
        let accepted = acceptsDrop
        draggingWorkspaceId = nil
        return accepted
    }
}

/// Applies the workspace reorder drop target only when a delegate is supplied,
/// so rows rendered without drag wiring (previews, tests) stay inert.
private struct SupermuxWorkspaceReorderDrop: ViewModifier {
    let delegate: SupermuxWorkspaceDropDelegate?

    func body(content: Content) -> some View {
        if let delegate {
            content.onDrop(of: [.plainText, .text], delegate: delegate)
        } else {
            content
        }
    }
}

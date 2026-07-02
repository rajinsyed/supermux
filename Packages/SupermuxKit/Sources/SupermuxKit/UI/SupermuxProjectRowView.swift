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
    /// Renames a nested open workspace by id (sets its custom title).
    public var renameWorkspace: (UUID) -> Void
    /// Moves the project one slot up in sidebar order (no-op when first).
    public var moveUp: () -> Void
    /// Moves the project one slot down in sidebar order (no-op when last).
    public var moveDown: () -> Void
    /// Reorders a nested workspace `(draggedId, targetId)` within this project.
    public var reorderWorkspace: (UUID, UUID) -> Void
    /// Opens a pull request's URL. The second argument is the open workspace
    /// the badge belongs to (`nil` for an unopened worktree's badge), so the
    /// host can open the PR *in that workspace* rather than whichever one is
    /// currently selected.
    public var openPullRequest: (URL, UUID?) -> Void

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
        renameWorkspace: @escaping (UUID) -> Void = { _ in },
        moveUp: @escaping () -> Void = {},
        moveDown: @escaping () -> Void = {},
        reorderWorkspace: @escaping (UUID, UUID) -> Void = { _, _ in },
        openPullRequest: @escaping (URL, UUID?) -> Void = { _, _ in }
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
        self.renameWorkspace = renameWorkspace
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.reorderWorkspace = reorderWorkspace
        self.openPullRequest = openPullRequest
    }
}

/// Live drag-reorder for project rows. As the dragged row hovers over another
/// project, `move` shuffles the previewed order so the list follows the cursor;
/// the drop ends the drag via `end` (which commits the previewed order once and
/// clears the markers). Holds only a binding to the host's drag state plus
/// value closures, so it respects the sidebar snapshot rule.
public struct SupermuxProjectDropDelegate: DropDelegate {
    let targetProjectId: UUID
    @Binding var draggingProjectId: UUID?
    /// `(draggedId, targetId)` — previews the dragged project over the target.
    let move: (UUID, UUID) -> Void
    /// Ends the drag (commit + clear); falls back to clearing the marker.
    let end: (() -> Void)?

    /// Creates the reorder drop delegate for one target row.
    /// - Parameters:
    ///   - targetProjectId: The project this row represents.
    ///   - draggingProjectId: Shared binding to the in-flight drag, if any.
    ///   - move: Previews `(draggedId, targetId)` in the host's drag state.
    ///   - end: Ends the drag, committing the previewed order and clearing the
    ///     markers; when omitted the delegate just clears the binding.
    public init(
        targetProjectId: UUID,
        draggingProjectId: Binding<UUID?>,
        move: @escaping (UUID, UUID) -> Void,
        end: (() -> Void)? = nil
    ) {
        self.targetProjectId = targetProjectId
        self._draggingProjectId = draggingProjectId
        self.move = move
        self.end = end
    }

    /// Whether the in-flight drag is a project reorder. Any project drag
    /// qualifies — after a live preview the dragged row usually sits under the
    /// cursor, so dropping "on itself" is the normal way a reorder ends.
    /// Foreign drags (terminal text, paths, workspace rows) are refused so
    /// they fall through instead of being silently swallowed.
    private var acceptsDrop: Bool { draggingProjectId != nil }

    public func dropEntered(info: DropInfo) {
        guard let dragged = draggingProjectId, dragged != targetProjectId else { return }
        move(dragged, targetProjectId)
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: acceptsDrop ? .move : .forbidden)
    }

    public func performDrop(info: DropInfo) -> Bool {
        guard acceptsDrop else { return false }
        if let end {
            end()
        } else {
            draggingProjectId = nil
        }
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
        // Computed once per row value (both inputs are immutable): body reads
        // this three times per pass, and hover/drag re-renders re-run body but
        // not init, so the path standardization never repeats. Shares the
        // open-vs-unopened rule with the PR-probe target computation via
        // SupermuxUnopenedWorktrees.
        let openDirs = SupermuxUnopenedWorktrees.openDirectories(openWorkspaces)
        self.unopenedWorktrees = SupermuxUnopenedWorktrees.filter(worktrees, openDirectories: openDirs)
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
                    rename: { actions.renameWorkspace(workspace.id) },
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
                    openPullRequest: { url in actions.openPullRequest(url, workspace.id) }
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
    /// disclosure never duplicates a nested workspace row. Precomputed in init.
    private let unopenedWorktrees: [SupermuxProjectWorktree]

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
            openPullRequest: { url in actions.openPullRequest(url, nil) }
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
                .frame(width: 20 * fontScale)
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
        // Match the open-workspace row so worktree names align under the project name.
        .padding(.leading, 7)
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


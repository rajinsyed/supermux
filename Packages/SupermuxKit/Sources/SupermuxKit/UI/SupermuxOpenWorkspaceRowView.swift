public import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An indented live-workspace row nested under its project: selectable, with a
/// selection highlight and a hover close button.
struct SupermuxOpenWorkspaceRowView: View {
    let workspace: SupermuxOpenWorkspace
    let select: () -> Void
    let close: () -> Void
    /// Renames the workspace (sets its custom title) via the host.
    var rename: () -> Void = {}
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
            // Empty leading placeholder matching the project avatar's width so
            // the title aligns under the project name (activity moved to the right).
            Color.clear
                .frame(width: 20 * fontScale, height: 12 * fontScale)
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
            // Agent activity (spinner / pulsing / ready dot) sits on the trailing
            // edge alongside the PR and run status, so it reads as a status
            // indicator rather than an avatar; idle workspaces show nothing.
            if workspace.activity.isVisible {
                SupermuxAgentActivityIndicator(activity: workspace.activity, size: 6 * fontScale)
            }
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
        // 7 + slot(20·s) + 6 == project row's 6 + avatar(20·s) + 7 → title aligns under the project name.
        .padding(.leading, 7)
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
            Button(String(localized: "supermux.workspace.rename", defaultValue: "Rename Workspace…"), action: rename)
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
        // Only write when a drag marker is actually set: a foreign drop must
        // not fire an @Observable mutation that re-renders every row.
        if draggingWorkspaceId != nil { draggingWorkspaceId = nil }
        return accepted
    }
}

/// Applies the workspace reorder drop target only when a delegate is supplied,
/// so rows rendered without drag wiring (previews, tests) stay inert.
struct SupermuxWorkspaceReorderDrop: ViewModifier {
    let delegate: SupermuxWorkspaceDropDelegate?

    func body(content: Content) -> some View {
        if let delegate {
            content.onDrop(of: [.plainText, .text], delegate: delegate)
        } else {
            content
        }
    }
}

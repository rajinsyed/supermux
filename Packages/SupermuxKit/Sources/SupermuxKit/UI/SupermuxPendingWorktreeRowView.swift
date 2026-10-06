public import SwiftUI

/// A value snapshot of one worktree being created in the background
/// (``SupermuxPendingWorktreeCreation/row``), so rows compare by value and
/// hold no store.
public struct SupermuxPendingWorktreeRow: Identifiable, Equatable, Sendable {
    /// The create's id.
    public let id: UUID
    /// The name the workspace is expected to open as.
    public let title: String
    /// What is happening ("Creating worktree…", "Creating on <Mac>…"), or
    /// that it failed.
    public let status: String
    /// The full error once it failed (the row's tooltip).
    public let detail: String?
    /// Whether the create failed: the row then reopens its sheet.
    public let isFailed: Bool
    /// Whether Cancel still applies (AI naming; git cannot be taken back).
    public let canCancel: Bool
}

/// What a pending worktree row does, by the create's id.
public struct SupermuxPendingWorktreeActions {
    /// Cancels a create that is still naming.
    public var cancel: (UUID) -> Void
    /// Removes a failed create's row.
    public var dismiss: (UUID) -> Void
    /// Shows a failed create's sheet again, everything typed still in it.
    public var reopen: (UUID) -> Void

    /// Creates the actions.
    public init(cancel: @escaping (UUID) -> Void, dismiss: @escaping (UUID) -> Void, reopen: @escaping (UUID) -> Void) {
        self.cancel = cancel
        self.dismiss = dismiss
        self.reopen = reopen
    }

    /// No-op actions (previews, and rows without background creates).
    public static var inert: SupermuxPendingWorktreeActions {
        SupermuxPendingWorktreeActions(cancel: { _ in }, dismiss: { _ in }, reopen: { _ in })
    }
}

/// A worktree being created in the background, nested under its project like
/// an open workspace: a spinner, the name it will open as, and what is
/// happening. A failed one shows the error instead; clicking it reopens the
/// New Worktree sheet with everything typed, and its ✕ dismisses it.
///
/// `Equatable` over its row value (hosts apply `.equatable()`); the actions
/// only forward this row's id to the host's stable callbacks.
struct SupermuxPendingWorktreeRowView: View, Equatable {
    let row: SupermuxPendingWorktreeRow
    let actions: SupermuxPendingWorktreeActions

    @Environment(\.supermuxSidebarFontScale) private var fontScale
    @State private var isHovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 6) {
            // The avatar column, like the open-workspace rows, so the title
            // aligns under the project name.
            leadingIcon
                .frame(width: 20 * fontScale, height: 12 * fontScale)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.system(size: 11.5 * fontScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.status)
                    .font(.system(size: 9.5 * fontScale))
                    .foregroundStyle(row.isFailed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 2)
            if isHovered, let close = closeButton {
                Button(action: close.action) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5 * fontScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(close.help)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        // Same insets as the open-workspace row.
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovered && row.isFailed ? 0.06 : 0))
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { if row.isFailed { actions.reopen(row.id) } }
        .contextMenu { menu }
        .help(row.detail ?? row.status)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isFailed ? .isButton : [])
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if row.isFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9 * fontScale, weight: .semibold))
                .foregroundStyle(Color.red)
        } else {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(fontScale)
        }
    }

    /// The hover ✕: Dismiss for a failed create, Cancel while it is naming,
    /// nothing while git runs.
    private var closeButton: (action: () -> Void, help: String)? {
        if row.isFailed {
            return ({ actions.dismiss(row.id) }, dismissTitle)
        }
        if row.canCancel {
            return ({ actions.cancel(row.id) }, cancelTitle)
        }
        return nil
    }

    @ViewBuilder
    private var menu: some View {
        if row.isFailed {
            Button(
                String(localized: "supermux.pendingWorktree.reopen", defaultValue: "Edit and Try Again…")
            ) { actions.reopen(row.id) }
            Button(dismissTitle) { actions.dismiss(row.id) }
        } else if row.canCancel {
            Button(cancelTitle) { actions.cancel(row.id) }
        }
    }

    private var dismissTitle: String {
        String(localized: "supermux.pendingWorktree.dismiss", defaultValue: "Dismiss")
    }

    private var cancelTitle: String {
        String(localized: "supermux.pendingWorktree.cancel", defaultValue: "Cancel Creating Worktree")
    }
}

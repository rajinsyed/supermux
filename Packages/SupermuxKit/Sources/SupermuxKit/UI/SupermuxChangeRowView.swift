import SwiftUI

/// One file row in the Changes panel: kind badge, file name, directory, and
/// hover actions. Clicking the row (outside its action buttons) opens the
/// file's diff through `onOpen`; the last-opened row stays highlighted.
///
/// Receives an immutable ``SupermuxGitFileChange`` value plus optional action
/// closures — never the changes model — so it stays below the panel's
/// `LazyVStack` snapshot boundary without holding an observable store.
struct SupermuxChangeRowView: View {
    let change: SupermuxGitFileChange
    /// Whether this row is the one whose diff was last opened.
    var isSelected = false
    /// Opens the file's diff; `nil` leaves the row inert (no host viewer).
    var onOpen: (() -> Void)?
    let onStage: (() -> Void)?
    let onUnstage: (() -> Void)?
    let onDiscard: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        rowContent
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 4))
            // The whole row (padding included) is clickable, not just the text.
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            .onHover { isHovering = $0 }
            .help(rowHelp)
            .modifier(OpenAccessibility(onOpen: onOpen))
    }

    /// Exposes the row as a button with a default action only when it can
    /// open a diff; an inert row offers VoiceOver and Full Keyboard Access
    /// nothing to activate.
    private struct OpenAccessibility: ViewModifier {
        let onOpen: (() -> Void)?

        func body(content: Content) -> some View {
            if let onOpen {
                content
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, onOpen)
            } else {
                content
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            kindBadge
            Text(change.fileName)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
            if let directory = change.directory {
                Text(directory)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if isHovering {
                hoverActions
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return Color.primary.opacity(isHovering ? 0.06 : 0)
    }

    private var rowHelp: String {
        onOpen == nil
            ? change.path
            : String(localized: "supermux.changes.row.open.help", defaultValue: "Open diff for \(change.path)")
    }

    private var kindBadge: some View {
        Text(kindBadgeStyle.letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(kindBadgeStyle.color)
            .frame(width: 14, height: 14)
            .background(kindBadgeStyle.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            .help(kindLabel)
            .accessibilityLabel(kindLabel)
    }

    @ViewBuilder
    private var hoverActions: some View {
        if let onDiscard {
            rowButton(
                "arrow.uturn.backward",
                help: String(localized: "supermux.changes.row.discard.help", defaultValue: "Discard changes"),
                action: onDiscard
            )
        }
        if let onStage {
            rowButton(
                "plus",
                help: String(localized: "supermux.changes.row.stage.help", defaultValue: "Stage file"),
                action: onStage
            )
        }
        if let onUnstage {
            rowButton(
                "minus",
                help: String(localized: "supermux.changes.row.unstage.help", defaultValue: "Unstage file"),
                action: onUnstage
            )
        }
    }

    private func rowButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var kindBadgeStyle: (letter: String, color: Color) {
        switch change.kind {
        case .modified: ("M", .yellow)
        case .added: ("A", .green)
        case .deleted: ("D", .red)
        case .renamed: ("R", .blue)
        case .copied: ("C", .blue)
        case .untracked: ("U", .secondary)
        case .conflicted: ("!", .orange)
        case .typeChanged: ("T", .yellow)
        }
    }

    private var kindLabel: String {
        switch change.kind {
        case .modified: String(localized: "supermux.changes.kind.modified", defaultValue: "Modified")
        case .added: String(localized: "supermux.changes.kind.added", defaultValue: "Added")
        case .deleted: String(localized: "supermux.changes.kind.deleted", defaultValue: "Deleted")
        case .renamed: String(localized: "supermux.changes.kind.renamed", defaultValue: "Renamed")
        case .copied: String(localized: "supermux.changes.kind.copied", defaultValue: "Copied")
        case .untracked: String(localized: "supermux.changes.kind.untracked", defaultValue: "Untracked")
        case .conflicted: String(localized: "supermux.changes.kind.conflicted", defaultValue: "Conflicted")
        case .typeChanged: String(localized: "supermux.changes.kind.typeChanged", defaultValue: "Type changed")
        }
    }
}

public import CmuxAgentChat
public import CmuxAgentChatUI
public import SwiftUI

/// The collapsed "Working…" summary standing in for a run of tool calls.
///
/// Tapping expands the run in place; tapping again folds it back. Collapsed,
/// it names what the agent last did rather than just counting rows, so the
/// user can tell "reading files" from "running the build" without expanding.
public struct SupermuxChatWorkGroupRow: View {
    private let group: SupermuxChatFocusGrouping.WorkGroup
    private let isExpanded: Bool
    private let isWorking: Bool
    private let actions: ChatRowActions
    private let onToggle: () -> Void

    @Environment(\.chatTheme) private var theme

    /// Creates a work-group row.
    ///
    /// - Parameters:
    ///   - group: The folded run.
    ///   - isExpanded: Whether the run is currently shown.
    ///   - isWorking: Whether the agent is still working, which shimmers the
    ///     label so a live run reads as live.
    ///   - actions: Row action bundle, forwarded to expanded rows.
    ///   - onToggle: Flips the expanded state.
    public init(
        group: SupermuxChatFocusGrouping.WorkGroup,
        isExpanded: Bool,
        isWorking: Bool,
        actions: ChatRowActions,
        onToggle: @escaping () -> Void
    ) {
        self.group = group
        self.isExpanded = isExpanded
        self.isWorking = isWorking
        self.actions = actions
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryButton
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.rows) { row in
                        ChatTranscriptRowView(row: row, actions: actions)
                            .equatable()
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    // A hairline rail ties the expanded rows to their summary,
                    // so a long run still reads as one unit while scrolling.
                    Rectangle()
                        .fill(theme.hairline)
                        .frame(width: 1)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryButton: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                if isWorking, !isExpanded {
                    SupermuxChatShimmerText(text: title, font: .footnote)
                } else {
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SupermuxChatWorkGroup-\(group.id)")
        .accessibilityLabel(title)
        .accessibilityHint(
            isExpanded
                ? String(
                    localized: "supermux.chat.focus.collapse.hint",
                    defaultValue: "Hides these steps",
                    bundle: .module
                )
                : String(
                    localized: "supermux.chat.focus.expand.hint",
                    defaultValue: "Shows these steps",
                    bundle: .module
                )
        )
        .accessibilityAddTraits(isExpanded ? [.isSelected] : [])
    }

    /// Collapsed: "Working · 7 steps" while live, else "7 steps". Expanded: the
    /// plain count, since the rows themselves are now on screen.
    private var title: String {
        let steps = String(
            localized: "supermux.chat.focus.steps",
            defaultValue: "\(group.count) steps",
            bundle: .module
        )
        guard isWorking, !isExpanded else { return steps }
        let working = String(
            localized: "supermux.chat.focus.working",
            defaultValue: "Working",
            bundle: .module
        )
        return "\(working) · \(steps)"
    }
}

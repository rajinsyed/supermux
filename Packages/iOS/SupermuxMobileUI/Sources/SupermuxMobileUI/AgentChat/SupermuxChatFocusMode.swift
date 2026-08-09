#if os(iOS)
public import CmuxAgentChat
public import CmuxAgentChatUI
public import SwiftUI

/// Installs focus mode on the chat surface beneath this view.
///
/// Focus mode folds consecutive runs of agent work rows (tool calls, thinking,
/// shell output, diffs) behind one expandable "Working" summary, so the
/// transcript reads as the conversation rather than as a build log. Prose,
/// user prompts, questions, and permission requests are never folded.
///
/// The expanded/collapsed state is owned HERE, above the transcript, rather
/// than inside each summary row. That matters: the transcript is a UITableView
/// that decides whether to reload by comparing item identity, so a tap that
/// only flipped some child view's private `@State` would resize a cell the
/// table does not know changed — the classic self-sizing drift. Keeping the
/// state here means a tap changes the grouping's identity, which forces a
/// clean reload.
public struct SupermuxChatFocusModifier: ViewModifier {
    private let isEnabled: Bool

    /// Ids of work groups the user has expanded.
    @State private var expandedGroupIDs: Set<String> = []

    /// Creates the modifier.
    ///
    /// - Parameter isEnabled: Whether focus mode is on.
    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public func body(content: Content) -> some View {
        content.chatTranscriptGrouping(isEnabled ? grouping : nil)
    }

    private var grouping: ChatTranscriptGrouping {
        // The identity carries the expanded set, so expanding or collapsing a
        // group reliably re-renders the transcript.
        let identity = "supermux.focus.v1#\(expandedGroupIDs.sorted().joined(separator: ","))"
        return ChatTranscriptGrouping(identity: identity) { rows, actions, agentState in
            entries(rows: rows, actions: actions, agentState: agentState)
        }
    }

    private func entries(
        rows: [ChatTranscriptRow],
        actions: ChatRowActions,
        agentState: ChatAgentState
    ) -> [ChatTranscriptGrouping.Entry] {
        let items = SupermuxChatFocusGrouping().items(for: rows)
        let isWorking: Bool
        if case .working = agentState { isWorking = true } else { isWorking = false }

        return items.map { item in
            switch item {
            case .row(let row):
                return ChatTranscriptGrouping.Entry(
                    id: row.id,
                    view: AnyView(
                        ChatTranscriptRowView(row: row, actions: actions).equatable()
                    )
                )
            case .workGroup(let group):
                // Only the LAST group can still be in flight; an earlier run is
                // finished work no matter what the agent is doing now.
                let isLast = items.last?.id == item.id
                return ChatTranscriptGrouping.Entry(
                    id: group.id,
                    view: AnyView(
                        SupermuxChatWorkGroupRow(
                            group: group,
                            isExpanded: expandedGroupIDs.contains(group.id),
                            isWorking: isWorking && isLast,
                            actions: actions,
                            onToggle: { toggle(group.id) }
                        )
                    )
                )
            }
        }
    }

    private func toggle(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }
}

public extension View {
    /// Installs supermux focus mode on the chat surface below.
    ///
    /// - Parameter isEnabled: Whether focus mode is on. When `false` the
    ///   transcript renders exactly as upstream does.
    /// - Returns: The modified view.
    func supermuxChatFocusMode(isEnabled: Bool) -> some View {
        modifier(SupermuxChatFocusModifier(isEnabled: isEnabled))
    }
}
#endif

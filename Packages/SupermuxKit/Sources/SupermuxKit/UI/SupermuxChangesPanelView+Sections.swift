import SwiftUI

/// The Incoming (pullable) and Unpushed (outgoing) commit disclosure sections
/// for ``SupermuxChangesPanelView``.
///
/// Split out of the main panel file to keep it within the Swift file-length
/// budget. Both sections read the model here — in the panel, which owns the
/// `LazyVStack` snapshot boundary — and hand ``SupermuxCommitHistorySection``
/// only immutable value snapshots plus action closures.
extension SupermuxChangesPanelView {

    /// Incoming commits (`HEAD..@{upstream}`, what a pull would bring), ↓.
    var incomingSection: some View {
        SupermuxCommitHistorySection(
            title: String(localized: "supermux.changes.incoming.title", defaultValue: "Incoming"),
            directionSymbol: "arrow.down",
            count: model.incomingCount,
            isExpanded: isIncomingExpanded,
            commits: model.incomingCommits,
            hasMore: model.hasMoreIncoming,
            isLoading: model.isLoadingIncoming,
            emptyText: String(localized: "supermux.changes.incoming.empty", defaultValue: "No incoming commits"),
            expandHelp: String(localized: "supermux.changes.incoming.expand.help", defaultValue: "Show incoming commits"),
            collapseHelp: String(localized: "supermux.changes.incoming.collapse.help", defaultValue: "Hide incoming commits"),
            onToggle: { toggleIncoming() },
            onLoadMore: { Task { await model.loadMoreIncoming() } }
        )
    }

    /// Unpushed commits (`@{upstream}..HEAD`, what a push would send), ↑.
    var historySection: some View {
        SupermuxCommitHistorySection(
            title: String(localized: "supermux.changes.unpushed.title", defaultValue: "Unpushed"),
            directionSymbol: "arrow.up",
            count: model.outgoingCount,
            isExpanded: isHistoryExpanded,
            commits: model.commits,
            hasMore: model.hasMoreCommits,
            isLoading: model.isLoadingCommits,
            emptyText: String(localized: "supermux.changes.unpushed.empty", defaultValue: "No unpushed commits"),
            expandHelp: String(localized: "supermux.changes.unpushed.expand.help", defaultValue: "Show unpushed commits"),
            collapseHelp: String(localized: "supermux.changes.unpushed.collapse.help", defaultValue: "Hide unpushed commits"),
            onToggle: { toggleHistory() },
            onLoadMore: { Task { await model.loadMoreCommits() } }
        )
    }

    func toggleIncoming() {
        isIncomingExpanded.toggle()
        let expanded = isIncomingExpanded
        Task { await model.setIncomingExpanded(expanded) }
    }

    func toggleHistory() {
        isHistoryExpanded.toggle()
        let expanded = isHistoryExpanded
        Task { await model.setHistoryExpanded(expanded) }
    }
}

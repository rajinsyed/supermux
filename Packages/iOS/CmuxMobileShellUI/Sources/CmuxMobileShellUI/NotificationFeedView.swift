#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Store-free actions passed through the feed's lazy-list boundary.
struct NotificationFeedActions {
    let open: @MainActor (MobileNotificationFeedItem) -> Void
    let markRead: @MainActor (MobileNotificationFeedItem) -> Void
    let markUnread: @MainActor (MobileNotificationFeedItem) -> Void
    let markAllRead: @MainActor () -> Void
    let refresh: @MainActor @Sendable () async -> Void
}

/// Production notification-feed presentation. This view owns only UI projection
/// state; rows receive immutable item snapshots plus ``NotificationFeedActions``.
struct NotificationFeedView: View {
    let status: MobileNotificationFeedStatus
    let projection: NotificationFeedProjection
    let refreshesOnAppear: Bool
    let actions: NotificationFeedActions

    var body: some View {
        @Bindable var projection = projection

        VStack(spacing: 0) {
            NotificationFeedFilterBar(selection: $projection.filter)
            // SUPERMUX:begin notification-feed-project-row
            // No divider: the filter bar and the list now share one grouped
            // background, and a full-width rule across it reintroduces exactly
            // the boxed-in look the card layout removes.
            // SUPERMUX:end notification-feed-project-row
            NotificationFeedList(
                sections: projection.sections,
                sourceItemCount: projection.sourceItemCount,
                isSourceRebuilding: projection.isSourceRebuilding,
                hasStaleSourceSections: projection.hasStaleSourceSections,
                hasMoreRows: projection.hasMoreRows,
                filter: projection.filter,
                hasSearchQuery: !projection.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                status: status,
                actions: actions,
                loadMoreRows: { projection.extendRowWindow() }
            )
        }
        .navigationTitle(L10n.string("mobile.notificationFeed.title", defaultValue: "Notifications"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if projection.sourceUnreadCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: actions.markAllRead) {
                        Label(
                            L10n.string("mobile.notificationFeed.markAllRead", defaultValue: "Mark All Read"),
                            systemImage: "envelope.open"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(
                        L10n.string("mobile.notificationFeed.markAllRead", defaultValue: "Mark All Read")
                    )
                    .accessibilityIdentifier("MobileNotificationFeedMarkAllRead")
                }
            }
        }
        .task {
            guard refreshesOnAppear else { return }
            await actions.refresh()
        }
        .accessibilityIdentifier("MobileNotificationFeed")
    }
}

private struct NotificationFeedFilterBar: View {
    @Binding var selection: MobileNotificationFeedFilter

    var body: some View {
        Picker(
            L10n.string("mobile.notificationFeed.filter.label", defaultValue: "Notification filter"),
            selection: $selection
        ) {
            Text(L10n.string("mobile.notificationFeed.filter.all", defaultValue: "All"))
                .tag(MobileNotificationFeedFilter.all)
                .accessibilityIdentifier("MobileNotificationFeedFilterAll")
            Text(L10n.string("mobile.notificationFeed.filter.unread", defaultValue: "Unread"))
                .tag(MobileNotificationFeedFilter.unread)
                .accessibilityIdentifier("MobileNotificationFeedFilterUnread")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // SUPERMUX:begin notification-feed-project-row
        // Matches the list's grouped background rather than the plain system
        // background, so the bar reads as part of the same surface as the cards
        // instead of a separate strip stacked above them.
        .background(Color(uiColor: .systemGroupedBackground))
        // SUPERMUX:end notification-feed-project-row
        .accessibilityIdentifier("MobileNotificationFeedFilter")
    }
}

private struct NotificationFeedList: View {
    let sections: [NotificationFeedDaySection]
    let sourceItemCount: Int
    let isSourceRebuilding: Bool
    let hasStaleSourceSections: Bool
    let hasMoreRows: Bool
    let filter: MobileNotificationFeedFilter
    let hasSearchQuery: Bool
    let status: MobileNotificationFeedStatus
    let actions: NotificationFeedActions
    let loadMoreRows: @MainActor () -> Void

    var body: some View {
        List {
            if sourceItemCount > 0 {
                NotificationFeedAvailabilityBanner(status: status)
            }

            if sections.isEmpty {
                NotificationFeedEmptyRow(
                    state: emptyState,
                    retry: { Task { await actions.refresh() } }
                )
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { model in
                            NotificationFeedRow(model: model, actions: actions)
                                .equatable()
                                .disabled(hasStaleSourceSections)
                                .allowsHitTesting(!hasStaleSourceSections)
                                // SUPERMUX:begin notification-feed-project-row
                                // Applied HERE, not inside the row's own body:
                                // list-row modifiers must attach to the direct
                                // child of `ForEach`, and below `.equatable()`
                                // (an `EquatableView`) they are silently
                                // dropped — which left the cards with system
                                // separators and an opaque white row fill.
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                // SUPERMUX:end notification-feed-project-row
                        }
                    } header: {
                        NotificationFeedDayHeader(section: section)
                            // SUPERMUX:begin notification-feed-project-row
                            .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            // SUPERMUX:end notification-feed-project-row
                    }
                }
                if hasMoreRows {
                    NotificationFeedLoadMoreRow(loadMore: loadMoreRows)
                }
            }
        }
        // SUPERMUX:begin notification-feed-project-row
        // Plain style with an explicit grouped background, not `.insetGrouped`:
        // the cards supply their own inset, fill, and corner radius, and the
        // grouped style would wrap each one in a second system-drawn container.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        // SUPERMUX:end notification-feed-project-row
        .refreshable {
            await actions.refresh()
        }
        .accessibilityIdentifier("MobileNotificationFeedList")
    }

    private var emptyState: NotificationFeedEmptyState {
        NotificationFeedEmptyState.resolve(
            sourceItemCount: sourceItemCount,
            filter: filter,
            hasSearchQuery: hasSearchQuery,
            isSourceRebuilding: isSourceRebuilding,
            status: status
        )
    }
}

private struct NotificationFeedDayHeader: View {
    let section: NotificationFeedDaySection

    var body: some View {
        Group {
            switch section.kind {
            case .today:
                Text(L10n.string("mobile.notificationFeed.day.today", defaultValue: "Today"))
            case .yesterday:
                Text(L10n.string("mobile.notificationFeed.day.yesterday", defaultValue: "Yesterday"))
            case .dated:
                Text(section.id, format: .dateTime.weekday(.wide).month(.abbreviated).day())
            }
        }
        // SUPERMUX:begin notification-feed-project-row
        // Small uppercase over the old sentence-case subheadline: at the same
        // weight and size as a card's headline, a day header competed with the
        // rows it labels. Tracked caps read as a divider at a glance.
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .kerning(0.6)
        .foregroundStyle(.secondary)
        // SUPERMUX:end notification-feed-project-row
        .accessibilityIdentifier(dayAccessibilityIdentifier)
    }

    private var dayAccessibilityIdentifier: String {
        switch section.kind {
        case .today: "MobileNotificationFeedDayToday"
        case .yesterday: "MobileNotificationFeedDayYesterday"
        case .dated: "MobileNotificationFeedDayDated"
        }
    }
}
#endif

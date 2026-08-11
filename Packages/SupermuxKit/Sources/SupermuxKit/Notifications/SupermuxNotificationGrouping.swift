public import Foundation
public import SupermuxMobileCore

/// How the notifications panel arranges its rows.
public enum SupermuxNotificationGroupMode: String, Sendable, Equatable, CaseIterable {
    /// One flat, newest-first list — what the panel did before projects.
    case chronological
    /// Grouped under the owning project, projects ordered by their most recent
    /// notification. This is the mode that makes a busy feed legible: five
    /// agents finishing across three repos becomes three labelled stacks
    /// instead of fifteen interleaved rows you have to read one at a time.
    case project
}

/// One rendered section of the notifications panel.
///
/// A value type computed outside any view body, so the panel's list can stay a
/// pure projection of immutable snapshots (the lazy-list boundary rule).
public struct SupermuxNotificationSection<Item: Identifiable & Sendable>: Identifiable, Sendable {
    /// Stable section identity: the project id, or a fixed sentinel for the
    /// project-less bucket.
    public let id: String
    /// The owning project, or `nil` for notifications from unregistered
    /// workspaces.
    public let project: SupermuxNotificationProject?
    /// Notifications in this section, newest first.
    public let items: [Item]
    /// How many of ``items`` are unread.
    public let unreadCount: Int

    /// Creates a section.
    /// - Parameters:
    ///   - id: Stable section identity.
    ///   - project: The owning project, or `nil`.
    ///   - items: Notifications, newest first.
    ///   - unreadCount: Unread total within `items`.
    public init(
        id: String,
        project: SupermuxNotificationProject?,
        items: [Item],
        unreadCount: Int
    ) {
        self.id = id
        self.project = project
        self.items = items
        self.unreadCount = unreadCount
    }

    /// Section id used for notifications belonging to no project.
    public static var otherSectionID: String { "supermux.notifications.other" }
}

/// Groups notifications into project sections.
///
/// Pure and generic over the item type so the same grouping serves the macOS
/// panel (`TerminalNotification`) and any other surface that needs it, and so
/// it is unit-testable without either.
public enum SupermuxNotificationGrouping {
    /// Groups `items` by project, preserving the input's newest-first order
    /// inside each section and ordering sections by their newest notification.
    ///
    /// Project-less notifications collect into one trailing section — never
    /// interleaved with the project stacks, and never dropped.
    ///
    /// - Parameters:
    ///   - items: Notifications, already sorted newest first.
    ///   - project: Extracts the owning project from an item.
    ///   - isUnread: Whether an item counts toward its section's unread total.
    /// - Returns: Sections in display order.
    public static func sections<Item: Identifiable & Sendable>(
        for items: [Item],
        project: (Item) -> SupermuxNotificationProject?,
        isUnread: (Item) -> Bool
    ) -> [SupermuxNotificationSection<Item>] {
        var order: [String] = []
        var grouped: [String: (project: SupermuxNotificationProject?, items: [Item], unread: Int)] = [:]

        for item in items {
            let owner = project(item)
            let key = owner?.id ?? SupermuxNotificationSection<Item>.otherSectionID
            if grouped[key] == nil {
                // First sighting fixes both the section's order (input is
                // newest-first, so this is its newest notification) and its
                // project snapshot. Later items may carry a stale name from
                // before a rename; the newest wins, which is what the user
                // just saw in the sidebar.
                grouped[key] = (owner, [], 0)
                order.append(key)
            }
            grouped[key]?.items.append(item)
            if isUnread(item) {
                grouped[key]?.unread += 1
            }
        }

        let otherKey = SupermuxNotificationSection<Item>.otherSectionID
        let displayOrder = order.filter { $0 != otherKey } + order.filter { $0 == otherKey }
        return displayOrder.compactMap { key in
            guard let bucket = grouped[key] else { return nil }
            return SupermuxNotificationSection(
                id: key,
                project: bucket.project,
                items: bucket.items,
                unreadCount: bucket.unread
            )
        }
    }
}

import CmuxFoundation
import Bonsplit
import SwiftUI
// SUPERMUX:begin notifications-panel-redesign
import AppKit
import SupermuxKit
import SupermuxMobileCore
// SUPERMUX:end notifications-panel-redesign

struct NotificationsPage: View {
    let isFocused: Bool
    let isVisibleInUI: Bool

    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @FocusState private var focusedNotificationId: UUID?
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var phonePushConfigurationState =
        PhonePushClient.shared.configurationState
    // SUPERMUX:begin notifications-panel-redesign
    /// Unread-only filter. Off by default: the panel's job on open is "what
    /// happened", and hiding read rows by default makes the list appear to lose
    /// history.
    @State private var showsUnreadOnly = false
    /// Whether rows group under their project. Persisted, because it is a
    /// working style rather than a per-visit choice.
    @AppStorage("supermux.notifications.groupByProject") private var groupsByProject = true
    /// Whether the phone-forwarding controls are expanded. Collapsed by
    /// default — it is a settings block that used to occupy the top third of
    /// the panel before any notification was visible.
    @State private var showsDeliverySettings = false
    // SUPERMUX:end notifications-panel-redesign

    private var phonePushConfiguration: PhonePushConfiguration {
        phonePushConfigurationState.configuration
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // SUPERMUX:begin notifications-panel-redesign
            // The forwarding block is now a disclosure under the header rather
            // than a permanently-mounted settings slab above the feed.
            deliverySettingsSection
            hairline

            if !notificationStore.notificationMenuSnapshot.hasNotifications {
                emptyState
            } else if notificationStore.notifications.isEmpty {
                workspaceUnreadIndicatorState
            } else {
                notificationsList
            }
            // SUPERMUX:end notifications-panel-redesign
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: setInitialFocus)
        .onChange(of: notificationStore.notifications.first?.id) {
            setInitialFocus()
        }
        .onChange(of: isFocused) {
            setInitialFocus()
        }
        .onChange(of: isVisibleInUI) {
            setInitialFocus()
        }
    }

    // SUPERMUX:begin notifications-panel-redesign
    /// A separator quieter than a full `Divider`, so the panel reads as one
    /// surface with structure rather than a stack of boxed strips.
    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }

    /// Visible rows after the unread filter.
    private var visibleNotifications: [TerminalNotification] {
        guard showsUnreadOnly else { return notificationStore.notifications }
        return notificationStore.notifications.filter { !$0.isRead }
    }

    private var notificationsList: some View {
        // One tabId -> title index per render instead of an O(tabs) lookup per
        // row, so constructing the list costs O(rows + tabs) rather than
        // O(rows × tabs) (issue #5794).
        let tabTitles = AppDelegate.shared?.tabTitlesByTabId() ?? [:]
        let notifications = visibleNotifications
        // Icons are read ABOVE the lazy boundary and handed down as immutable
        // values: no view below a LazyVStack may hold a reference to an
        // observable store (CLAUDE.md / issue #2586).
        let icons = projectIcons(for: notifications)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: groupsByProject ? 18 : 6, pinnedViews: []) {
                if notifications.isEmpty {
                    filteredEmptyState
                } else if groupsByProject {
                    ForEach(sections(for: notifications)) { section in
                        projectSection(section, tabTitles: tabTitles, icons: icons)
                    }
                } else {
                    ForEach(notifications) { notification in
                        row(for: notification, tabTitles: tabTitles, icons: icons)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
    }

    /// Project sections, newest project first.
    private func sections(
        for notifications: [TerminalNotification]
    ) -> [SupermuxNotificationSection<TerminalNotification>] {
        SupermuxNotificationGrouping.sections(
            for: notifications,
            project: { $0.project },
            isUnread: { !$0.isRead }
        )
    }

    /// The decoded icon for every project present in `notifications`, resolved
    /// once per render above the list boundary.
    private func projectIcons(for notifications: [TerminalNotification]) -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for notification in notifications {
            guard let project = notification.project,
                  icons[project.id] == nil,
                  let uuid = UUID(uuidString: project.id),
                  let image = SupermuxComposition.projectIconStore.image(for: uuid)
            else { continue }
            icons[project.id] = image
        }
        return icons
    }

    @ViewBuilder
    private func projectSection(
        _ section: SupermuxNotificationSection<TerminalNotification>,
        tabTitles: [UUID: String],
        icons: [String: NSImage]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SupermuxNotificationSectionHeader(
                project: section.project,
                icon: section.project.flatMap { icons[$0.id] },
                count: section.items.count,
                unreadCount: section.unreadCount
            )
            .padding(.horizontal, 4)

            VStack(spacing: 4) {
                ForEach(section.items) { notification in
                    row(for: notification, tabTitles: tabTitles, icons: icons, showsAvatar: false)
                }
            }
        }
    }

    @ViewBuilder
    private func row(
        for notification: TerminalNotification,
        tabTitles: [UUID: String],
        icons: [String: NSImage],
        showsAvatar: Bool = true
    ) -> some View {
        NotificationRow(
            notification: notification,
            tabTitle: tabTitle(for: notification.tabId, in: tabTitles),
            isFocused: focusedNotificationId == notification.id,
            // In grouped mode the project header already carries the avatar, so
            // repeating it on every row would just be a column of duplicates.
            projectIcon: showsAvatar ? notification.project.flatMap { icons[$0.id] } : nil,
            showsProjectAvatar: showsAvatar,
            onOpen: {
                // SwiftUI action closures aren't guaranteed to be main-actor
                // isolated; hop to the main actor for window focus + tab selection.
                Task { @MainActor in
                    _ = AppDelegate.shared?.openTerminalNotification(notification)
                }
            },
            onClear: {
                notificationStore.remove(id: notification.id)
            },
            onToggleRead: {
                notificationStore.toggleReadFromUserAction(notification)
            },
            focusedNotificationId: $focusedNotificationId
        )
        // Each NotificationRow renders heavily-modified nested stacks.
        // Equatable + .equatable() lets a store publish that touches one
        // notification skip body re-evaluation for the other rows, instead of
        // re-laying out the whole LazyVStack on every publish (issue #5794,
        // same class as #2586 / #5752).
        .equatable()
    }

    /// Shown when the unread filter hides everything — distinct from "nothing
    /// ever arrived", which would otherwise read as lost history.
    private var filteredEmptyState: some View {
        VStack(spacing: 6) {
            CmuxSystemSymbolImage(magnified: "checkmark.circle", pointSize: 22)
                .foregroundStyle(.secondary)
            Text(String(localized: "supermux.notifications.allCaughtUp", defaultValue: "You're all caught up"))
                .cmuxFont(.subheadline, weight: .medium)
            Text(String(
                localized: "supermux.notifications.allCaughtUp.description",
                defaultValue: "Every notification has been read. Switch to All to see them again."
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
    // SUPERMUX:end notifications-panel-redesign

    private func setInitialFocus() {
        // Background-mounted pane tabs must not claim focus when their feed changes.
        guard isFocused,
              isVisibleInUI,
              let firstId = notificationStore.notifications.first?.id else {
            focusedNotificationId = nil
            return
        }
        focusedNotificationId = firstId
    }

    private var header: some View {
        // SUPERMUX:begin notifications-panel-redesign
        // Two tiers: an identity line (title + live unread count) over a
        // control line (filter, grouping, actions). The old single row pushed
        // Clear All against the title and had nowhere to put a filter.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                    .cmuxFont(.title3, weight: .semibold)

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .cmuxFont(size: 10.5, weight: .semibold, design: .rounded, monospacedDigit: true)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(cmuxAccentColor()))
                        .accessibilityLabel(Text(String(
                            localized: "supermux.notifications.unreadCount",
                            defaultValue: "\(unreadCount) unread"
                        )))
                }

                Spacer(minLength: 0)

                if notificationStore.notificationMenuSnapshot.hasNotifications {
                    jumpToUnreadButton
                }
            }

            if notificationStore.notificationMenuSnapshot.hasNotifications {
                headerControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // SUPERMUX:end notifications-panel-redesign
    }

    // SUPERMUX:begin notifications-panel-redesign
    private var unreadCount: Int {
        notificationStore.unreadNotificationCount
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $showsUnreadOnly) {
                Text(String(localized: "supermux.notifications.filter.all", defaultValue: "All"))
                    .tag(false)
                Text(String(localized: "supermux.notifications.filter.unread", defaultValue: "Unread"))
                    .tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("notificationsPage.filter")

            Button {
                groupsByProject.toggle()
            } label: {
                CmuxSystemSymbolImage(
                    systemName: groupsByProject
                        ? "rectangle.3.group.fill"
                        : "list.bullet",
                    pointSize: 12
                )
            }
            .buttonStyle(.accessoryBar)
            .safeHelp(groupsByProject
                ? String(
                    localized: "supermux.notifications.group.off",
                    defaultValue: "Show as one list"
                )
                : String(
                    localized: "supermux.notifications.group.on",
                    defaultValue: "Group by project"
                ))
            .accessibilityLabel(String(
                localized: "supermux.notifications.group.label",
                defaultValue: "Group by project"
            ))
            .accessibilityIdentifier("notificationsPage.groupByProject")

            Spacer(minLength: 0)

            if unreadCount > 0 {
                Button(String(
                    localized: "supermux.notifications.markAllRead",
                    defaultValue: "Mark All Read"
                )) {
                    notificationStore.markAllRead()
                }
                .buttonStyle(.accessoryBar)
            }

            Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                notificationStore.clearAll()
            }
            .buttonStyle(.accessoryBar)
        }
    }

    /// The phone-forwarding controls, behind a disclosure.
    private var deliverySettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) {
                    showsDeliverySettings.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    CmuxSystemSymbolImage(
                        systemName: showsDeliverySettings ? "chevron.down" : "chevron.right",
                        pointSize: 9
                    )
                    .foregroundStyle(.secondary)
                    Text(String(
                        localized: "supermux.notifications.delivery.title",
                        defaultValue: "Delivery"
                    ))
                    .cmuxFont(.caption, weight: .medium)
                    .foregroundStyle(.secondary)
                    Text(deliverySummary)
                        .cmuxFont(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notificationsPage.deliveryDisclosure")

            if showsDeliverySettings {
                phoneForwardingRow
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// One-line state of phone forwarding, so the collapsed disclosure still
    /// answers "is my phone getting these?" without being expanded.
    private var deliverySummary: String {
        guard phonePushConfiguration.forwardingEnabled else {
            return String(
                localized: "supermux.notifications.delivery.summary.off",
                defaultValue: "This Mac only"
            )
        }
        switch phonePushConfiguration.mode {
        case .always:
            return String(
                localized: "supermux.notifications.delivery.summary.always",
                defaultValue: "Also on iPhone"
            )
        case .onlyWhenAway:
            return String(
                localized: "supermux.notifications.delivery.summary.away",
                defaultValue: "On iPhone when away"
            )
        }
    }
    // SUPERMUX:end notifications-panel-redesign

    private var phoneForwardingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: forwardToPhoneBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "notifications.forwardToPhone.title", defaultValue: "Forward notifications to my iPhone"))
                    Text(String(localized: "notifications.forwardToPhone.subtitle", defaultValue: "Send local agent notifications to cmux on your iPhone. Enabled by default; turn this off to stop this Mac from forwarding them."))
                        .cmuxFont(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityIdentifier("notificationsPage.forwardToPhone")
            if phonePushConfiguration.forwardingEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(
                        String(localized: "notifications.forwardToPhone.mode.label", defaultValue: "When to send"),
                        selection: forwardToPhoneModeBinding
                    ) {
                        Text(String(localized: "notifications.forwardToPhone.mode.onlyWhenAway", defaultValue: "Only when away from this Mac"))
                            .tag(PhoneForwardingMode.onlyWhenAway.rawValue)
                        Text(String(localized: "notifications.forwardToPhone.mode.always", defaultValue: "Always"))
                            .tag(PhoneForwardingMode.always.rawValue)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .cmuxFont(.caption)
                    if phonePushConfiguration.mode == .onlyWhenAway {
                        Text(awayModeExplanation)
                            .cmuxFont(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 20)
                Toggle(isOn: hidePhoneNotificationContentBinding) {
                    Text(String(localized: "notifications.forwardToPhone.hideContent", defaultValue: "Hide content (send a generic message instead of the terminal text)"))
                        .cmuxFont(.caption)
                }
                .padding(.leading, 20)
            }
        }
    }

    private var forwardToPhoneBinding: Binding<Bool> {
        Binding(
            get: { phonePushConfiguration.forwardingEnabled },
            set: { enabled in
                PhonePushClient.shared.updateSettings(
                    forwardingEnabled: enabled
                )
            }
        )
    }

    private var forwardToPhoneModeBinding: Binding<String> {
        Binding(
            get: { phonePushConfiguration.mode.rawValue },
            set: { rawValue in
                guard let mode = PhoneForwardingMode(rawValue: rawValue) else {
                    return
                }
                PhonePushClient.shared.updateSettings(
                    mode: mode
                )
            }
        )
    }

    private var hidePhoneNotificationContentBinding: Binding<Bool> {
        Binding(
            get: { phonePushConfiguration.hideContent },
            set: { hideContent in
                PhonePushClient.shared.updateSettings(
                    hideContent: hideContent
                )
            }
        )
    }

    private var awayModeExplanation: String {
        let format = String(
            localized: "notifications.forwardToPhone.mode.subtitle",
            defaultValue: "Away means the screen is locked or asleep, the screensaver is running, or there has been no keyboard or mouse input for %lld minutes."
        )
        return String(format: format, Int64(MacPresenceMonitor.recentHardwareInputThreshold / 60))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            CmuxSystemSymbolImage(magnified: "bell.slash", pointSize: 32)
                .foregroundColor(.secondary)
            Text(String(localized: "notifications.empty.title", defaultValue: "No notifications yet"))
                .cmuxFont(.headline)
            Text(String(localized: "notifications.empty.description", defaultValue: "Desktop notifications will appear here for quick review."))
                .cmuxFont(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceUnreadIndicatorState: some View {
        VStack(spacing: 8) {
            CmuxSystemSymbolImage(magnified: "bell.badge", pointSize: 32)
                .foregroundColor(.secondary)
            Text(notificationStore.notificationMenuSnapshot.stateHintTitle)
                .cmuxFont(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var jumpToUnreadButton: some View {
        if let key = jumpToUnreadShortcut.keyEquivalent {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(key, modifiers: jumpToUnreadShortcut.eventModifiers)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        } else {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        }
    }

    private var jumpToUnreadShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
    }

    private func tabTitle(for tabId: UUID, in tabTitles: [UUID: String]) -> String? {
        tabTitles[tabId] ?? tabManager.tabs.first(where: { $0.id == tabId })?.title
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notificationMenuSnapshot.hasUnreadNotifications
    }
}

struct ShortcutAnnotation: View {
    let text: String
    var accessibilityIdentifier: String? = nil

    @ViewBuilder
    var body: some View {
        if let accessibilityIdentifier {
            badge.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            badge
        }
    }

    private var badge: some View {
        Text(text)
            .cmuxFont(size: 10, weight: .semibold, design: .rounded)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}

// SUPERMUX:begin notifications-panel-redesign
/// A project's section header: avatar, name, and the section's unread/total
/// counts. Takes immutable values only — it renders below the panel's list
/// boundary and must never hold a store reference.
struct SupermuxNotificationSectionHeader: View, Equatable {
    let project: SupermuxNotificationProject?
    let icon: NSImage?
    let count: Int
    let unreadCount: Int

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project
            && lhs.count == rhs.count
            && lhs.unreadCount == rhs.unreadCount
            && lhs.icon === rhs.icon
    }

    var body: some View {
        HStack(spacing: 8) {
            if let project {
                SupermuxNotificationAvatarView(project: project, image: icon, size: 20)
                Text(project.name)
                    .cmuxFont(size: 11.5, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                CmuxSystemSymbolImage(systemName: "square.stack", pointSize: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(String(
                    localized: "supermux.notifications.otherProjects",
                    defaultValue: "Other workspaces"
                ))
                .cmuxFont(size: 11.5, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if unreadCount > 0 {
                Circle()
                    .fill(cmuxAccentColor())
                    .frame(width: 5, height: 5)
            }

            Spacer(minLength: 0)

            Text("\(count)")
                .cmuxFont(size: 10.5, weight: .medium, monospacedDigit: true)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
// SUPERMUX:end notifications-panel-redesign

struct NotificationRow: View, Equatable {
    // Closures and the focus binding are recreated by the parent on every render
    // and excluded from ==. Equality compares only the value snapshot the row
    // actually renders, so `.equatable()` can suppress body re-evaluation for
    // rows whose snapshot is unchanged (snapshot-boundary rule, CLAUDE.md /
    // issue #2586). `isFocused` is passed in (rather than read from the binding
    // inside the row) precisely so it participates in equality — otherwise a
    // focus change would leave the default-action shortcut on a stale row.
    nonisolated static func == (lhs: NotificationRow, rhs: NotificationRow) -> Bool {
        lhs.notification == rhs.notification &&
            lhs.tabTitle == rhs.tabTitle &&
            lhs.isFocused == rhs.isFocused &&
            // SUPERMUX:begin notifications-panel-redesign
            // Identity compare: the icon store hands out one NSImage instance
            // per project and replaces it only when the bytes change, so this
            // is both correct and cheaper than pixel comparison.
            lhs.projectIcon === rhs.projectIcon &&
            lhs.showsProjectAvatar == rhs.showsProjectAvatar
            // SUPERMUX:end notifications-panel-redesign
    }

    let notification: TerminalNotification
    let tabTitle: String?
    let isFocused: Bool
    // SUPERMUX:begin notifications-panel-redesign
    /// The owning project's decoded icon, resolved above the list boundary.
    var projectIcon: NSImage? = nil
    /// Whether this row draws its own avatar. `false` in grouped mode, where
    /// the section header already carries it.
    var showsProjectAvatar: Bool = true
    // SUPERMUX:end notifications-panel-redesign
    let onOpen: () -> Void
    let onClear: () -> Void
    // SUPERMUX:begin notifications-panel-redesign
    /// Toggles read state. The panel had no such affordance while the titlebar
    /// popover did — the same notification could be marked read in one surface
    /// and not the other.
    var onToggleRead: () -> Void = {}
    // SUPERMUX:end notifications-panel-redesign
    let focusedNotificationId: FocusState<UUID?>.Binding

    // SUPERMUX:begin notifications-panel-redesign
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NotificationRow.\(notification.id.uuidString)")
            .focusable()
            .focused(focusedNotificationId, equals: notification.id)
            .modifier(DefaultActionModifier(isActive: isFocused))
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAction(
                named: Text(String(localized: "notifications.row.clear", defaultValue: "Clear notification"))
            ) { onClear() }

            // Hover-only, so the resting row is content rather than chrome.
            Button(action: onClear) {
                CmuxSystemSymbolImage(systemName: "xmark.circle.fill", pointSize: 13)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(8)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            // Dismissal is reachable via the row's accessibility action and the
            // context menu, so keep an invisible button out of keyboard focus.
            .accessibilityHidden(true)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .contextMenu {
            Button(String(localized: "notifications.open", defaultValue: "Open"), action: onOpen)
            Button(notification.isRead
                ? String(localized: "notifications.markAsUnread", defaultValue: "Mark as Unread")
                : String(localized: "notifications.markAsRead", defaultValue: "Mark as Read"),
                action: onToggleRead)
            Divider()
            Button(
                String(localized: "notifications.dismiss", defaultValue: "Dismiss"),
                role: .destructive,
                action: onClear
            )
        }
    }

    /// The row body: a leading unread rail, an optional project avatar, then a
    /// title/provenance/body stack.
    ///
    /// The rail replaces the old free-floating dot — as a full-height bar it
    /// reads as "this row is unread" rather than as a bullet point, and it
    /// leaves the title line free for the timestamp alone.
    private var rowContent: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(notification.isRead ? Color.clear : cmuxAccentColor())
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            if showsProjectAvatar, let project = notification.project {
                SupermuxNotificationAvatarView(project: project, image: projectIcon, size: 28)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notification.title)
                        .cmuxFont(size: 12.5, weight: notification.isRead ? .medium : .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    Text(notification.createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .cmuxFont(size: 10.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let provenance {
                    Text(provenance)
                        .cmuxFont(size: 10.5, weight: .medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let preview {
                    Text(preview)
                        .cmuxFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.leading, 8)
        .padding(.trailing, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0.035))
        )
        .contentShape(Rectangle())
    }

    /// `project · tab`, minus whatever the section header or the title already
    /// said. Hidden entirely when it would only repeat something on screen.
    private var provenance: String? {
        SupermuxNotificationProvenance.line(
            projectName: showsProjectAvatar ? notification.project?.name : nil,
            tabName: tabTitle
        )
        .flatMap { line in
            SupermuxNotificationProvenance.matches(line, notification.title) ? nil : line
        }
    }

    /// The body, or the subtitle when the body adds nothing. The subtitle was
    /// carried end-to-end but never rendered anywhere in the app before this.
    private var preview: String? {
        let redundant = [notification.title, tabTitle, notification.project?.name]
            .compactMap { SupermuxNotificationProvenance.normalized($0) }
        if let body = SupermuxNotificationProvenance.normalized(notification.body),
           !redundant.contains(where: { SupermuxNotificationProvenance.matches(body, $0) }) {
            return body
        }
        if let subtitle = SupermuxNotificationProvenance.normalized(notification.subtitle),
           !redundant.contains(where: { SupermuxNotificationProvenance.matches(subtitle, $0) }) {
            return subtitle
        }
        return nil
    }

    private var accessibilityLabel: String {
        [
            notification.isRead
                ? String(localized: "notifications.markAsRead", defaultValue: "Mark as Read")
                : String(localized: "supermux.notifications.unread", defaultValue: "Unread"),
            notification.title,
            provenance,
            preview,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
    // SUPERMUX:end notifications-panel-redesign
}

private struct DefaultActionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

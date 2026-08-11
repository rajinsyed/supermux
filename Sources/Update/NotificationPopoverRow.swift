import CmuxFoundation
// SUPERMUX:begin notification-popover-redesign
import AppKit
import SupermuxKit
// The row's shared line logic moved to the cross-platform core so the iOS feed
// could use it too; SupermuxKit no longer re-exports it.
import SupermuxMobileCore
// SUPERMUX:end notification-popover-redesign
import SwiftUI

struct NotificationPopoverRow: View, Equatable {
    // Closures excluded from ==; equality is the rendered snapshot only (#2586).
    nonisolated static func == (lhs: NotificationPopoverRow, rhs: NotificationPopoverRow) -> Bool {
        lhs.notification == rhs.notification && lhs.workspaceTitle == rhs.workspaceTitle
            // SUPERMUX:begin notification-popover-redesign
            // Identity compare: the icon store hands out one NSImage per
            // project and replaces it only when the bytes change.
            && lhs.projectIcon === rhs.projectIcon
            && lhs.showsProjectAvatar == rhs.showsProjectAvatar
            // SUPERMUX:end notification-popover-redesign
    }

    let notification: TerminalNotification
    let workspaceTitle: String?
    // SUPERMUX:begin notification-popover-redesign
    /// The owning project's decoded icon, resolved above the popover's list.
    var projectIcon: NSImage? = nil
    /// Whether this row draws its own avatar. `false` under a project section
    /// header, which already carries it.
    var showsProjectAvatar: Bool = true
    // SUPERMUX:end notification-popover-redesign
    let onOpen: () -> Void
    let onClear: () -> Void
    let onToggleRead: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        // Row uses a ZStack so the hover-only clear button is a *sibling* of the row's
        // primary-action Button, not nested in its label. Nested SwiftUI buttons don't
        // produce reliable independent hit targets on macOS — clicks on a nested button
        // can be consumed by the outer button's tap area.
        ZStack(alignment: .topTrailing) {
            // Primary row action wrapped as a Button so the row participates in the
            // key-view loop: keyboard users can tab to a row and activate it with
            // space/return. Visual styling is owned by rowContent; the button background
            // lets the NSTrackingArea-driven hover tint shine through.
            Button(action: onOpen) {
                rowContent
            }
            .buttonStyle(.plain)
            // Identifier/action live on the Button itself so XCUITest's
            // `app.buttons["NotificationPopoverRow.<id>"]` query keeps matching. A previous
            // pass put them on the combined outer ZStack, which exposed the row as a
            // container rather than a button to accessibility clients.
            .accessibilityIdentifier("NotificationPopoverRow.\(notification.id.uuidString)")
            // XCUITest's `.click()` isn't always reliable for SwiftUI buttons hosted in an
            // `NSPopover`. Provide an explicit accessibility action so AXPress always routes to onOpen.
            .accessibilityAction { onOpen() }
            // The clear button is hover-only for pointer users; expose dismiss as a row-level
            // accessibility action so VoiceOver / keyboard / assistive tech can dismiss too.
            .accessibilityAction(
                named: Text(String(localized: "notifications.row.clear", defaultValue: "Clear notification"))
            ) {
                onClear()
            }

            clearButton
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                // Dismissal is exposed through the row Button's accessibility action and the
                // context menu, so hide this hover-only affordance from keyboard focus /
                // VoiceOver when not visible — otherwise Full Keyboard Access can tab to an
                // invisible button.
                .accessibilityHidden(!isHovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hover detection runs through an AppKit NSTrackingArea (HoverTrackingRepresentable)
        // because SwiftUI's `.onHover` / `.onContinuousHover` arbitrate with the row's
        // primary action and miss enter/exit events right after the popover opens and when
        // the pointer crosses between LazyVStack rows.
        .background(
            HoverTrackingRepresentable { hovering in
                if isHovering != hovering { isHovering = hovering }
            }
        )
        .contextMenu {
                Button(String(localized: "notifications.open", defaultValue: "Open")) {
                    onOpen()
                }
                if notification.isRead {
                    Button(String(localized: "notifications.markAsUnread", defaultValue: "Mark as Unread")) {
                        onToggleRead()
                    }
                } else {
                    Button(String(localized: "notifications.markAsRead", defaultValue: "Mark as Read")) {
                        onToggleRead()
                    }
                }
                Divider()
                Button(String(localized: "notifications.dismiss", defaultValue: "Dismiss"), role: .destructive) {
                    onClear()
                }
            }
    }

    // SUPERMUX:begin notification-popover-redesign
    // The row body is the SHARED one (Sources/Supermux/SupermuxNotificationRowBody.swift),
    // not a second layout. The popover and the notifications panel list the same
    // notifications from the same store; before this they drew them with two
    // independent bodies, so the redesign landed only in the panel while the
    // popover — the surface behind the bell button and ⌘I, which is what most
    // people actually open — kept the old look.
    private var rowContent: some View {
        SupermuxNotificationRowBody(
            project: notification.project,
            projectIcon: projectIcon,
            showsAvatar: showsProjectAvatar,
            headline: headline,
            provenance: provenance,
            preview: preview,
            timestamp: notification.createdAt,
            isRead: notification.isRead,
            isHovering: isHovering,
            // Kept: MultiWindowNotificationsWorkspaceHeadlineUITests queries this
            // identifier to assert the row headline tracks a workspace rename.
            headlineAccessibilityIdentifier: workspaceTitle.map { _ in
                "NotificationPopoverRow.\(notification.id.uuidString).workspaceTitle"
            }
        )
    }

    private var headline: String {
        SupermuxNotificationRowPresentation.headline(
            title: notification.title,
            tabName: workspaceTitle
        )
    }

    private var provenance: String? {
        SupermuxNotificationRowPresentation.provenance(
            projectName: showsProjectAvatar ? notification.project?.name : nil,
            title: notification.title,
            headline: headline
        )
    }

    private var preview: String? {
        SupermuxNotificationRowPresentation.preview(
            body: notification.body,
            subtitle: notification.subtitle,
            redundant: [headline, provenance, notification.project?.name]
        )
    }
    // SUPERMUX:end notification-popover-redesign

    private var clearButton: some View {
        Button(action: onClear) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.1))
                CmuxSystemSymbolImage(systemName: "xmark", pointSize: 9, weight: .bold)
                    .foregroundColor(.primary.opacity(0.7))
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .padding(8)
    }
}

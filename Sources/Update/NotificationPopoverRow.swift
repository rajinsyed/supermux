import CmuxFoundation
// SUPERMUX:begin notification-popover-project-avatar
import AppKit
import SupermuxKit
// SUPERMUX:end notification-popover-project-avatar
import SwiftUI

struct NotificationPopoverRow: View, Equatable {
    // Closures excluded from ==; equality is the rendered snapshot only (#2586).
    nonisolated static func == (lhs: NotificationPopoverRow, rhs: NotificationPopoverRow) -> Bool {
        lhs.notification == rhs.notification && lhs.workspaceTitle == rhs.workspaceTitle
            // SUPERMUX:begin notification-popover-project-avatar
            // Identity compare: the icon store hands out one NSImage per
            // project and replaces it only when the bytes change.
            && lhs.projectIcon === rhs.projectIcon
            // SUPERMUX:end notification-popover-project-avatar
    }

    let notification: TerminalNotification
    let workspaceTitle: String?
    // SUPERMUX:begin notification-popover-project-avatar
    /// The owning project's decoded icon, resolved above the popover's list.
    var projectIcon: NSImage? = nil
    // SUPERMUX:end notification-popover-project-avatar
    let onOpen: () -> Void
    let onClear: () -> Void
    let onToggleRead: () -> Void

    @State private var isHovering: Bool = false

    private static let rowHeight: CGFloat = 56

    var body: some View {
        // Row uses a ZStack so the hover-only clear button is a *sibling* of the row's
        // primary-action Button, not nested in its label. Nested SwiftUI buttons don't
        // produce reliable independent hit targets on macOS — clicks on a nested button
        // can be consumed by the outer button's tap area.
        ZStack(alignment: .trailing) {
            // Primary row action wrapped as a Button so the row participates in the
            // key-view loop: keyboard users can tab to a row and activate it with
            // space/return. Visual styling is owned by rowContent; the button background
            // lets the NSTrackingArea-driven hover tint shine through.
            Button(action: onOpen) {
                rowContent
                    .background(
                        Color.primary.opacity(isHovering ? 0.11 : 0)
                    )
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
                .padding(.trailing, 10)
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

    private var rowContent: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(notification.isRead ? Color.clear : cmuxAccentColor())
                .frame(width: 2.5)
                .padding(.vertical, 6)

            // SUPERMUX:begin notification-popover-project-avatar
            // The same project avatar the panel and the phone show, so a
            // notification is recognizable in every surface it appears in.
            // Takes the immutable snapshot the notification already carries plus
            // an image resolved above the popover's LazyVStack — no store
            // reference crosses the list boundary.
            if let project = notification.project {
                SupermuxNotificationAvatarView(project: project, image: projectIcon, size: 24)
                    .padding(.leading, 10)
            }
            // SUPERMUX:end notification-popover-project-avatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let workspaceTitle, !workspaceTitle.isEmpty {
                        Text(workspaceTitle)
                            .cmuxFont(size: 12.5, weight: .semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .accessibilityIdentifier(
                                "NotificationPopoverRow.\(notification.id.uuidString).workspaceTitle"
                            )
                    } else {
                        Text(notification.title)
                            .cmuxFont(size: 12.5, weight: .semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                        .cmuxFont(size: 10.5)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 34)
                        .layoutPriority(2)
                }

                if let workspaceTitle, !workspaceTitle.isEmpty {
                    Text(notification.title)
                        .cmuxFont(size: 10.5, weight: .medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if !notification.body.isEmpty {
                    Text(notification.body)
                        .cmuxFont(size: 11.5)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .frame(minHeight: Self.rowHeight)
        .padding(.leading, 4)
    }

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
    }
}

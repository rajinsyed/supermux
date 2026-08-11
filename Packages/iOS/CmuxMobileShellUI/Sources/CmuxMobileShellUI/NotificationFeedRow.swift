#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
// SUPERMUX:begin notification-feed-project-row
import SupermuxMobileUI
// SUPERMUX:end notification-feed-project-row
import SwiftUI

struct NotificationFeedRow: View, Equatable {
    let model: NotificationFeedRowModel
    let actions: NotificationFeedActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
    }

    private var item: MobileNotificationFeedItem { model.item }

    var body: some View {
        Button {
            open()
        } label: {
            NotificationFeedRowLabel(
                createdAt: item.createdAt,
                isRead: item.isRead,
                presentation: model.presentation
            )
        }
        .buttonStyle(.plain)
        // The card draws its own surface, inset, and separation; the list-row
        // chrome that would otherwise fight it (separators, opaque row fill,
        // default insets) is cleared where the row is mounted in
        // `NotificationFeedList` — those modifiers do not survive being applied
        // beneath this view's `.equatable()`.
        .contextMenu(menuItems: {
            Button {
                open()
            } label: {
                Label(
                    L10n.string("mobile.notificationFeed.open", defaultValue: "Open"),
                    systemImage: "arrow.up.forward.app"
                )
            }
            .accessibilityIdentifier("MobileNotificationFeedOpenMenu-\(accessibilitySuffix)")

            if !item.isRead {
                Button {
                    actions.markRead(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read"),
                        systemImage: "envelope.open"
                    )
                }
                .accessibilityIdentifier("MobileNotificationFeedMarkReadMenu-\(accessibilitySuffix)")
            } else {
                Button {
                    actions.markUnread(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markUnread", defaultValue: "Mark as Unread"),
                        systemImage: "envelope.badge"
                    )
                }
                .accessibilityIdentifier("MobileNotificationFeedMarkUnreadMenu-\(accessibilitySuffix)")
            }
        })
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !item.isRead {
                Button {
                    actions.markRead(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read"),
                        systemImage: "envelope.open"
                    )
                }
                .tint(.blue)
                .accessibilityIdentifier("MobileNotificationFeedMarkReadSwipe-\(accessibilitySuffix)")
            } else {
                Button {
                    actions.markUnread(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markUnread", defaultValue: "Mark as Unread"),
                        systemImage: "envelope.badge"
                    )
                }
                .tint(.blue)
                .accessibilityIdentifier("MobileNotificationFeedMarkUnreadSwipe-\(accessibilitySuffix)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        // SUPERMUX:begin notification-feed-project-row
        // The headline, not the raw title: it is what the row actually shows,
        // and VoiceOver announcing "Claude Code" for a row reading "fix
        // notifications" would describe a different row than the visible one.
        .accessibilityLabel(model.presentation.headline)
        // SUPERMUX:end notification-feed-project-row
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(L10n.string(
            "mobile.notificationFeed.openHint",
            defaultValue: "Opens this notification's workspace."
        ))
        .accessibilityActions {
            Button(L10n.string("mobile.notificationFeed.open", defaultValue: "Open")) {
                open()
            }
            if !item.isRead {
                Button(L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read")) {
                    actions.markRead(item)
                }
            } else {
                Button(L10n.string("mobile.notificationFeed.markUnread", defaultValue: "Mark as Unread")) {
                    actions.markUnread(item)
                }
            }
        }
        .accessibilityIdentifier("MobileNotificationFeedRow-\(accessibilitySuffix)")
    }

    private func open() {
        actions.open(item)
    }

    private var accessibilitySuffix: String {
        "\(item.macDeviceID)-\(item.notificationID)"
    }

    /// Joins the precomputed details with a render-time relative date, so the
    /// spoken timestamp stays current even when cached models republish.
    private var accessibilityValue: String {
        (model.presentation.accessibilityDetails
            + [item.createdAt.formatted(.relative(presentation: .named))])
            .formatted()
    }
}

// SUPERMUX:begin notification-feed-project-row
/// One notification, drawn as a card.
///
/// The previous row was a flat list line: a 6pt unread dot, then a stack of
/// four same-weight lines (title, `folder` project, `desktopcomputer` computer,
/// body) separated by hairlines. At a glance nothing dominated — the agent name
/// repeated down every row in the strongest position while the workspace, the
/// one fact that differs between rows, sat in muted 11pt text below.
///
/// This redesign fixes the hierarchy rather than the paint:
///
/// - The **headline is the workspace** (shared with both Mac surfaces), so what
///   varies between rows is what you read first.
/// - The avatar is the row's anchor at 38pt, large enough to identify a project
///   by its logo alone while scrolling.
/// - Provenance and the message preview drop to one muted line each, with the
///   preview clamped to two lines — the old three-line clamp let one chatty
///   notification fill a third of the screen.
/// - Cards on a grouped background replace hairline separators: an unread card
///   carries a tinted surface and a soft accent border, so read state is legible
///   from the whole card rather than from a 6pt dot.
private struct NotificationFeedRowLabel: View {
    let createdAt: Date
    let isRead: Bool
    let presentation: NotificationFeedRowPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                NotificationFeedHeadline(
                    headline: presentation.headline,
                    createdAt: createdAt,
                    isRead: isRead
                )

                if let provenance = presentation.provenance {
                    NotificationFeedProvenance(text: provenance)
                }

                if let contentPreview = presentation.contentPreview {
                    NotificationFeedContentPreview(text: contentPreview)
                        .padding(.top, 1)
                }

                NotificationFeedComputer(
                    name: presentation.computerName,
                    isReachable: presentation.connectionStatus == .connected
                )
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }

    /// The project avatar, or a neutral bell for a notification with no project
    /// (an upstream Mac, or a workspace in no project). A placeholder rather
    /// than nothing: without it those rows lose the leading column and their
    /// text hangs off a different left edge than every card above them.
    @ViewBuilder
    private var avatar: some View {
        if let project = presentation.project {
            SupermuxNotificationAvatar(project: project, size: 38)
        } else {
            RoundedRectangle(cornerRadius: 38 * 0.3, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "bell.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tertiary)
                )
                .accessibilityHidden(true)
        }
    }

    /// Unread cards get a tinted fill and a soft accent hairline; read cards sit
    /// on a plain elevated surface. Both are opacity-based so the card works on
    /// either appearance without a second palette.
    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isRead ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(Color.accentColor.opacity(0.09)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isRead ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.28),
                        lineWidth: 1
                    )
            )
    }
}

/// The row's primary line and its timestamp.
///
/// The unread dot moved here from the row's leading edge, where it cost a column
/// of width on every row to mark a minority of them. Beside the timestamp it
/// reads as a status on this notification, and the avatar keeps the leading edge
/// aligned for every card.
private struct NotificationFeedHeadline: View {
    let headline: String
    let createdAt: Date
    let isRead: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(headline)
                .font(.subheadline.weight(isRead ? .semibold : .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .layoutPriority(1)

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Text(createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if !isRead {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// The `project · title` line. A plain muted line rather than the old
/// symbol-prefixed one: with the avatar carrying project identity, a `folder`
/// glyph on the text beside it labels the same fact twice.
private struct NotificationFeedProvenance: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The originating Mac. Last and quietest: it is the fact you check when
/// something looks wrong, not one you scan for. Keeps its symbol because,
/// unlike the project, nothing else on the card says "computer" — and keeps the
/// orange unreachable state, which is a warning rather than decoration.
private struct NotificationFeedComputer: View {
    let name: String
    let isReachable: Bool

    var body: some View {
        (Text(Image(systemName: "desktopcomputer")) + Text(" ") + Text(name))
            .font(.caption2)
            .foregroundStyle(isReachable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
            .lineLimit(1)
    }
}

private struct NotificationFeedContentPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
// SUPERMUX:end notification-feed-project-row
#endif

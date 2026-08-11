import AppKit
import CmuxFoundation
import SupermuxKit
import SupermuxMobileCore
import SwiftUI

/// The rendered body of one notification row, shared by every macOS surface
/// that lists notifications.
///
/// It exists because there are two of them. The notifications **panel**
/// (`NotificationsPage`) and the titlebar **popover** (`NotificationsPopoverView`)
/// show the same notifications from the same store, and before this they drew
/// them with two independent bodies: different fonts, different timestamp
/// formats, one with a project avatar and one without. Whichever one the user
/// happened to open decided what the feature looked like — the popover is the
/// one behind the bell button and ⌘I, so it is the one most people see.
///
/// Per the fork's shared-behavior rule, a behavior exposed through several
/// entrypoints gets ONE implementation and every entrypoint is verified against
/// it. This is that implementation for the row's presentation.
///
/// Takes immutable values only — a project snapshot, an already-decoded icon,
/// and pre-composed strings — so it is safe below a `LazyVStack` boundary and
/// holds no store reference (the issue-2586 rule).
struct SupermuxNotificationRowBody: View {
    /// The owning project, when the notification has one.
    let project: SupermuxNotificationProject?
    /// The project's decoded icon, resolved above the list boundary.
    let projectIcon: NSImage?
    /// Whether this row draws its own avatar. `false` under a project section
    /// header, which already carries it.
    let showsAvatar: Bool
    /// The row's primary line: what the user scans for.
    let headline: String
    /// The `project · …` line under the headline, already de-duplicated by
    /// ``SupermuxNotificationProvenance``.
    let provenance: String?
    /// The message preview, when it adds anything beyond the lines above.
    let preview: String?
    /// When the notification fired.
    let timestamp: Date
    /// Read state, which drives the leading unread rail and headline weight.
    let isRead: Bool
    /// Whether the pointer is over the row.
    let isHovering: Bool
    /// Accessibility identifier for the headline element. The popover's
    /// workspace-headline UI test queries a specific identifier, so the caller
    /// supplies it rather than this view inventing one.
    var headlineAccessibilityIdentifier: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // A full-height rail rather than a free-floating dot: at row scale a
            // bar reads as "this row is unread", while a dot reads as a bullet
            // point and competes with the text it sits beside.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isRead ? Color.clear : cmuxAccentColor())
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            if showsAvatar, let project {
                SupermuxNotificationAvatarView(project: project, image: projectIcon, size: 28)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    headlineText
                    Spacer(minLength: 4)
                    // Relative ("2m") rather than a wall-clock time: a feed is
                    // read as "how long ago", and it stays narrow enough not to
                    // squeeze the headline in the popover's smaller width.
                    Text(timestamp, format: .relative(presentation: .numeric, unitsStyle: .narrow))
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
        // Room for the hover-only clear button, which overlays the trailing edge.
        .padding(.trailing, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0.035))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var headlineText: some View {
        let text = Text(headline)
            .cmuxFont(size: 12.5, weight: isRead ? .medium : .semibold)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .layoutPriority(1)
        if let headlineAccessibilityIdentifier {
            text.accessibilityIdentifier(headlineAccessibilityIdentifier)
        } else {
            text
        }
    }
}

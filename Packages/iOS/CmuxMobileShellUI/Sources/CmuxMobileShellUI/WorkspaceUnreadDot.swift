import SwiftUI

// SUPERMUX:begin supermux-unread-badge-capsule
import SupermuxMobileCore
import SupermuxMobileUI

/// The single unread indicator for workspace rows.
///
/// This used to be a bare accent dot in a fixed-width gutter that every row
/// reserved, drawn or not. Two problems were visible on a phone: the Mac showed
/// a numbered badge for the same workspace while the phone showed a countless
/// dot, and the always-present gutter left a blank column down the entire list.
///
/// Now it wraps ``SupermuxMobileUnreadBadge``, which shares its geometry with
/// the Mac's badge through `SupermuxUnreadBadgeStyle`, and it occupies no space
/// at all when the workspace is read. Rows lay the badge out inline instead of
/// reserving a column for it.
struct WorkspaceUnreadDot: View {
    let isUnread: Bool
    /// The unread count, when the paired Mac reports one. `nil` (an upstream
    /// cmux Mac, or a group header's rolled-up boolean) draws the countless
    /// dot form of the same badge.
    var unreadCount: Int?
    /// Point size of the badge numeral; every other dimension derives from it.
    var fontSize: CGFloat = 10

    var body: some View {
        if isUnread {
            SupermuxMobileUnreadBadge(count: unreadCount, fontSize: fontSize)
                // The badge is decorative here; rows fold the unread state into
                // their combined accessibility summary instead.
                .accessibilityHidden(true)
        }
    }

    /// What the badge contributes to a wrapping row's height, for the table's
    /// height cache: `nil` when nothing renders, otherwise the exact string
    /// drawn.
    ///
    /// The drawn text, not the raw count, is the width-determining value — 100
    /// and 4000 both render "99+" and must share one cache entry, while 9 and 10
    /// must not. An unread badge occupying title-row width can push a
    /// barely-fitting title onto another line, so a cache that ignored this
    /// would clip that line until an unrelated event invalidated it.
    static func heightIdentity(isUnread: Bool, unreadCount: Int?) -> String? {
        guard isUnread else { return nil }
        // "" is the countless dot: distinct from nil (nothing drawn) and from
        // any numeral.
        return SupermuxUnreadBadgeStyle.displayText(count: unreadCount) ?? ""
    }
}
// SUPERMUX:end supermux-unread-badge-capsule

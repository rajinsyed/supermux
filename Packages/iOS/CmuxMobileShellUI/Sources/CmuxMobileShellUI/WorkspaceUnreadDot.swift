import CmuxMobileShellModel
// SUPERMUX:begin supermux-unread-badge-capsule
import SupermuxMobileCore
import SupermuxMobileUI
// SUPERMUX:end supermux-unread-badge-capsule
import SwiftUI

/// The single unread indicator for workspace rows: an accent badge showing the
/// unread count (parity with the Mac sidebar's workspace unread badge, which
/// is always numeric), in a fixed-width gutter to the LEFT of the workspace
/// icon. Against a Mac old enough to report only the boolean, the badge shows
/// the minimum count that boolean implies (1) — never a count-less dot, so
/// marking a workspace unread reads "1" exactly like the Mac.
///
/// Every row renders this gutter (the indicator is just hidden when read), so
/// read and unread rows keep their icon and text columns aligned. Shared by
/// the flat workspace list and the group headers; any future surface that
/// marks a workspace unread should reuse it rather than invent another badge.
struct WorkspaceUnreadDot: View {
    /// Width every row reserves for the indicator column, kept narrow so the
    /// list does not drift right. Indicators are LEADING-aligned in it: the
    /// badge is wider than the dot, and anchoring both to the same left edge
    /// keeps the leading margin identical whether a row shows a dot, a badge,
    /// or nothing. All overflow goes toward the next element, which every
    /// surface must reserve through ``layoutGap(afterGutterForDiameter:leftShift:visualGap:)``.
    static let gutterWidth: CGFloat = 10

    /// The width a surface must lay out between the gutter and its next
    /// element so that element keeps `visualGap` points of daylight from the
    /// badge's trailing edge. The badge is leading-aligned in the gutter and
    /// wider than it, so its trailing edge lands `diameter - leftShift` from
    /// the gutter's leading edge — past the gutter itself. `WorkspaceRow`
    /// (rail column) and `WorkspaceGroupHeaderRow` (disclosure chevron) both
    /// space off the badge with this one formula; a surface that skips it puts
    /// its next element inside the badge's overflow.
    static func layoutGap(
        afterGutterForDiameter diameter: Double,
        leftShift: Double,
        visualGap: CGFloat
    ) -> CGFloat {
        let indicatorTrailing = CGFloat(diameter) - CGFloat(leftShift)
        return max(0, visualGap + indicatorTrailing - gutterWidth)
    }
    let unread: MobileWorkspaceUnreadState
    var leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift
    var diameter: Double = MobileDisplaySettings.defaultUnreadBadgeDiameter

    init(
        unread: MobileWorkspaceUnreadState,
        leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
        diameter: Double = MobileDisplaySettings.defaultUnreadBadgeDiameter
    ) {
        self.unread = unread
        self.leftShift = leftShift
        self.diameter = diameter
    }

    init(
        isUnread: Bool,
        leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
        diameter: Double = MobileDisplaySettings.defaultUnreadBadgeDiameter
    ) {
        self.init(
            unread: MobileWorkspaceUnreadState(isUnread: isUnread, count: nil),
            leftShift: leftShift,
            diameter: diameter
        )
    }

    /// The number the badge shows: the exact count when known, otherwise the
    /// minimum an unread boolean implies (1). A `0` from a skewed payload also
    /// clamps to 1 — an unread row must never render an empty circle.
    private var badgeCount: Int? {
        guard unread.isUnread else { return nil }
        return max(unread.count ?? 1, 1)
    }

    // SUPERMUX:begin supermux-unread-badge-capsule
    /// Point size of the badge numeral; every other dimension derives from it.
    var fontSize: CGFloat = 10

    /// Supermux renders the shared cross-platform capsule
    /// (``SupermuxMobileUnreadBadge``, geometry shared with the Mac through
    /// `SupermuxUnreadBadgeStyle`) instead of upstream's fixed-gutter circle,
    /// and occupies NO space at all when the workspace is read: rows lay the
    /// badge out inline after the title rather than reserving a column for it,
    /// which is what left a blank column down the whole list. The gutter
    /// statics above stay only for upstream's layout math and debug lab;
    /// `leftShift`/`diameter` are accepted but inert. A `nil` count (a Mac
    /// that reports only the boolean) draws the countless dot form.
    var body: some View {
        if unread.isUnread {
            SupermuxMobileUnreadBadge(count: unread.count, fontSize: fontSize)
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
    /// `nonisolated`: the table's layout key (a plain `Hashable` value) derives
    /// it outside the main actor.
    nonisolated static func heightIdentity(isUnread: Bool, unreadCount: Int?) -> String? {
        guard isUnread else { return nil }
        // "" is the countless dot: distinct from nil (nothing drawn) and from
        // any numeral.
        return SupermuxUnreadBadgeStyle.displayText(count: unreadCount) ?? ""
    }
    // SUPERMUX:end supermux-unread-badge-capsule
}

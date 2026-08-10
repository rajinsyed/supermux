import SwiftUI
import AppKit

struct SidebarWorkspaceLeadingStatusSlot: View {
    let showsBadge: Bool
    let showsSpinner: Bool
    let unreadCount: Int
    let side: CGFloat
    let spinnerSide: CGFloat
    // SUPERMUX:begin supermux-unread-badge-capsule (added parameter)
    /// The numeral's point size. The shared badge builds its font and derives
    /// every other dimension from this already-magnified value.
    let badgePointSize: CGFloat
    // SUPERMUX:end supermux-unread-badge-capsule
    let badgeFillColor: Color
    let badgeTextColor: Color
    let spinnerColor: NSColor
    let spinnerTooltip: String

    var body: some View {
        ZStack {
            if showsBadge {
                SidebarWorkspaceUnreadBadge(
                    unreadCount: unreadCount,
                    side: side,
                    pointSize: badgePointSize,
                    fillColor: badgeFillColor,
                    textColor: badgeTextColor
                )
                .opacity(showsSpinner ? 0 : 1)
            }
            if showsSpinner {
                SidebarWorkspaceLoadingSpinner(
                    side: spinnerSide,
                    color: spinnerColor,
                    tooltip: spinnerTooltip
                )
            }
        }
        // SUPERMUX:begin supermux-unread-badge-capsule (upstream pinned this slot
        // to a square `side` x `side` and clipped — see SUPERMUX-TOUCHPOINTS.md)
        // The badge is a capsule now, so a two-digit count is WIDER than it is
        // tall. Upstream's square frame plus `.clipped()` would shear the
        // second digit off. Height stays pinned (rows align on it); width is
        // only a minimum, so single digits keep the old circular footprint and
        // wider counts push the title over instead of being cut.
        .frame(minWidth: side, minHeight: side)
        // SUPERMUX:end supermux-unread-badge-capsule
    }
}

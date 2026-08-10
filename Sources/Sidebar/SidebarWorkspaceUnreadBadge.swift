import SwiftUI

// SUPERMUX:begin supermux-unread-badge-capsule
import SupermuxKit

/// The sidebar's unread badge, rendered by ``SupermuxUnreadBadgeView`` so the
/// Mac and the phone draw the same thing.
///
/// This used to be a flat accent `Circle` with a count centered in it, sized by
/// the caller. The replacement keeps the caller's contract — same call sites in
/// `ContentView` — and moves the geometry into the shared
/// `SupermuxUnreadBadgeStyle` the phone reads too. Two-digit counts now widen
/// into a capsule instead of being squeezed inside a fixed circle, and counts
/// past 99 render as "99+" rather than stretching the row.
///
/// `pointSize` rather than `side` drives the badge: the shared style derives
/// every dimension from the numeral's size. `side` is retained because callers
/// still use it to reserve the slot, but deriving the point size from it would
/// silently drop the user's global font magnification, which reaches this view
/// through `pointSize`.
struct SidebarWorkspaceUnreadBadge: View {
    let unreadCount: Int
    let side: CGFloat
    let pointSize: CGFloat
    let fillColor: Color
    let textColor: Color

    var body: some View {
        SupermuxUnreadBadgeView(
            count: unreadCount,
            fontSize: pointSize,
            fillColor: fillColor,
            textColor: textColor
        )
        // The caller's reserved height still wins, so rows keep aligning on the
        // slot they always had even if the shared ratio ever moves.
        .frame(minHeight: side)
    }
}
// SUPERMUX:end supermux-unread-badge-capsule

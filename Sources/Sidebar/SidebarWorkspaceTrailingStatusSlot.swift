import SwiftUI
import AppKit

struct SidebarWorkspaceTrailingStatusSlot: View {
    let showsSpinner: Bool
    let showsBadge: Bool
    let unreadCount: Int
    let side: CGFloat
    let width: CGFloat
    let height: CGFloat
    // SUPERMUX:begin supermux-unread-badge-capsule (added parameter)
    /// The numeral's point size. The shared badge builds its font and derives
    /// every other dimension from this already-magnified value.
    let badgePointSize: CGFloat
    // SUPERMUX:end supermux-unread-badge-capsule
    let badgeFillColor: Color
    let badgeTextColor: Color
    let spinnerColor: NSColor
    let spinnerTooltip: String
    let canCloseWorkspace: Bool
    let showsCloseButton: Bool
    let closeButtonTooltip: String
    let closeButtonColor: Color
    let closeButtonFontSize: CGFloat
    let closeAction: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            if showsSpinner {
                SidebarWorkspaceLoadingSpinner(side: side, color: spinnerColor, tooltip: spinnerTooltip)
                    .opacity(canCloseWorkspace && showsCloseButton ? 0 : 1)
                    .transition(.opacity)
            } else if showsBadge {
                SidebarWorkspaceUnreadBadge(
                    unreadCount: unreadCount,
                    side: side,
                    pointSize: badgePointSize,
                    fillColor: badgeFillColor,
                    textColor: badgeTextColor
                )
                .opacity(canCloseWorkspace && showsCloseButton ? 0 : 1)
                .transition(.opacity)
            }
            if canCloseWorkspace {
                Button(action: closeAction) {
                    CmuxSystemSymbolImage(magnified: "xmark", pointSize: closeButtonFontSize, weight: .medium)
                        .foregroundColor(closeButtonColor)
                        .frame(width: width, height: height, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .safeHelp(closeButtonTooltip)
                .opacity(showsCloseButton ? 1 : 0)
                .allowsHitTesting(showsCloseButton)
                .accessibilityHidden(!showsCloseButton)
            }
        }
        // SUPERMUX:begin supermux-unread-badge-capsule (upstream fixed this slot
        // at `width` — see SUPERMUX-TOUCHPOINTS.md)
        // `width` is the close button's reserved width, which a two-digit
        // capsule badge now exceeds. It becomes a minimum so the badge grows
        // leftward into the row instead of being clipped; the close button and
        // spinner still get exactly the width they always had.
        .frame(minWidth: width, minHeight: height, alignment: .trailing)
        // SUPERMUX:end supermux-unread-badge-capsule
    }
}

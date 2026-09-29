public import SwiftUI

/// Keeps the sidebar's workspace list out from under the sidebar footer
/// (account, usage, help, Upgrade).
///
/// The footer is drawn over the bottom of the scrolling list, which keeps
/// scrolling beneath it; upstream's bottom edge fade is shorter than the
/// footer, so rows showed through and their text collided with the buttons.
/// The list is masked out behind the footer and fades in just above it. The
/// footer keeps whatever background the sidebar has (material, glass or a
/// translucent terminal color), which an opaque fill could not match.
public enum SupermuxSidebarFooterClearance {
    /// How far above the footer the list fades out.
    public static let fadeHeight: CGFloat = 12
}

extension View {
    /// Masks this view (the sidebar's workspace list) out of the bottom
    /// `footerHeight` points, fading it in over the band just above. A zero
    /// height (no footer) masks nothing.
    public func supermuxClearsSidebarFooter(height footerHeight: CGFloat) -> some View {
        mask {
            VStack(spacing: 0) {
                Color.black
                if footerHeight > 0 {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: SupermuxSidebarFooterClearance.fadeHeight)
                    Color.clear
                        .frame(height: footerHeight)
                }
            }
        }
    }

    /// Reports this view's (the sidebar footer's) height into `height`, and
    /// zero once it leaves the screen.
    public func supermuxReportsSidebarFooterHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            height.wrappedValue = newHeight
        }
        .onDisappear { height.wrappedValue = 0 }
    }
}

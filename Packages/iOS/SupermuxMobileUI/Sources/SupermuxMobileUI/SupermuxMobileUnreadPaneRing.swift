public import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Draws the persistent blue unread ring around the visible mobile pane.
public struct SupermuxMobileUnreadPaneRing: View {
    private let style: SupermuxMobileUnreadPaneRingStyle

    /// Creates a ring using the geometry and glow of the macOS pane ring.
    /// - Parameter style: The ring appearance. Defaults to macOS parity.
    public init(style: SupermuxMobileUnreadPaneRingStyle = .macOSParity) {
        self.style = style
    }

    public var body: some View {
        let color = systemBlue
        RoundedRectangle(cornerRadius: CGFloat(style.cornerRadius))
            .stroke(color, lineWidth: CGFloat(style.lineWidth))
            .shadow(
                color: color.opacity(style.glowOpacity),
                radius: CGFloat(style.glowRadius)
            )
            .padding(CGFloat(style.inset))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var systemBlue: Color {
        #if os(iOS)
        Color(uiColor: .systemBlue)
        #elseif os(macOS)
        Color(nsColor: .systemBlue)
        #else
        Color.blue
        #endif
    }
}

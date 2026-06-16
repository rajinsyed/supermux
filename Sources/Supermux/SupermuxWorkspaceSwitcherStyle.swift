import AppKit
import SwiftUI

/// Visual constants and small helpers shared by the workspace switcher overlay.
enum SupermuxWorkspaceSwitcherStyle {
    /// Card preview thumbnail size (points) — compact, app-switcher scale.
    static let previewSize = CGSize(width: 128, height: 80)
    /// Spacing between cards.
    static let cardSpacing: CGFloat = 7
    /// Gap between a card's thumbnail and its name/branch label.
    static let cardLabelGap: CGFloat = 6
    /// Reserved height for a card's two-line label (workspace name + branch), so
    /// every card is the same height and the strip never jitters while cycling.
    static let cardLabelHeight: CGFloat = 30
    /// Full height of a card (thumbnail + gap + label). Drives the strip's fixed
    /// height (and the scroll viewport when the row overflows).
    static var cardHeight: CGFloat { previewSize.height + cardLabelGap + cardLabelHeight }
    /// Vertical breathing room added inside the scrolling viewport so the selected
    /// card's drop shadow isn't clipped by the `ScrollView`'s bounds.
    static let cardShadowBleed: CGFloat = 8
    /// Corner radius of the floating panel.
    static let panelCornerRadius: CGFloat = 14
    /// Corner radius of a card's preview.
    static let cardCornerRadius: CGFloat = 8
    /// Inner padding around the card strip.
    static let panelPadding: CGFloat = 10
    /// Max width the panel may reach before the strip scrolls horizontally; below
    /// this the panel hugs its cards (dynamic width).
    static let maxStripWidth: CGFloat = 720

    /// Parses a `#RRGGBB` (or `#RRGGBBAA`) hex string into a SwiftUI `Color`,
    /// returning `nil` for blank or malformed input so callers fall back to a
    /// neutral default.
    static func color(fromHex hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              let intValue = UInt64(value, radix: 16) else {
            return nil
        }
        let r, g, b, a: Double
        if value.count == 6 {
            r = Double((intValue >> 16) & 0xFF) / 255.0
            g = Double((intValue >> 8) & 0xFF) / 255.0
            b = Double(intValue & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((intValue >> 24) & 0xFF) / 255.0
            g = Double((intValue >> 16) & 0xFF) / 255.0
            b = Double((intValue >> 8) & 0xFF) / 255.0
            a = Double(intValue & 0xFF) / 255.0
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// A SwiftUI wrapper around `NSVisualEffectView` for the panel's frosted-glass
/// backdrop.
struct SupermuxVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

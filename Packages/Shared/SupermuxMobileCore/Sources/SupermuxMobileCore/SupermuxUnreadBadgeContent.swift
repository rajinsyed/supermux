public import SwiftUI

/// The ONE SwiftUI unread badge, rendered identically on macOS and iOS.
///
/// SwiftUI is cross-platform, so there is no reason for two badge views — an
/// earlier version of this had a Mac copy and a phone copy whose bodies were
/// line-for-line identical, which is precisely the drift the shared
/// ``SupermuxUnreadBadgeStyle`` exists to prevent. Colors are parameters
/// because they genuinely differ (the Mac resolves a per-window appearance and
/// a user-settable badge color from Settings; the phone always uses the accent
/// tint), and each platform keeps a thin wrapper that supplies them.
///
/// The Mac's pure-AppKit sidebar list still paints its own copy with Core
/// Graphics — that list is hand-laid-out for scroll performance and cannot host
/// SwiftUI per row — but it draws from the same style and the same gradient
/// stops, so it is a third renderer of one design, not a third design.
public struct SupermuxUnreadBadgeContent: View {
    private let count: Int?
    private let style: SupermuxUnreadBadgeStyle
    private let fillColor: Color
    private let textColor: Color

    /// Creates the badge.
    /// - Parameters:
    ///   - count: The unread count. `nil` or non-positive renders the countless
    ///     dot — which is what a phone paired with an upstream cmux Mac gets,
    ///     and what a group header's rolled-up boolean produces.
    ///   - fontSize: Point size of the numeral, already scaled by the caller
    ///     (the Mac's sidebar font scale and global magnification; the phone's
    ///     Dynamic Type). Every other dimension derives from it.
    ///   - fillColor: Base capsule color; the gradient is applied over it.
    ///   - textColor: Numeral color.
    public init(
        count: Int?,
        fontSize: CGFloat,
        fillColor: Color,
        textColor: Color
    ) {
        self.count = count
        self.style = SupermuxUnreadBadgeStyle(fontSize: fontSize)
        self.fillColor = fillColor
        self.textColor = textColor
    }

    public var body: some View {
        Group {
            if let text = SupermuxUnreadBadgeStyle.displayText(count: count) {
                Text(text)
                    .font(.system(size: style.fontSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
                    .padding(.horizontal, style.horizontalPadding)
                    .frame(minWidth: style.minimumWidth, minHeight: style.height)
                    .background(plate)
            } else {
                plate.frame(width: style.dotDiameter, height: style.dotDiameter)
            }
        }
        .compositingGroup()
        .shadow(
            color: fillColor.opacity(SupermuxUnreadBadgeStyle.shadowOpacity),
            radius: style.shadowRadius,
            y: style.shadowOffsetY
        )
    }

    /// The capsule itself: base color, light-from-above gradient, hairline rim.
    private var plate: some View {
        Capsule(style: .continuous)
            .fill(fillColor)
            .overlay {
                Capsule(style: .continuous)
                    .fill(SupermuxUnreadBadgeGradient.overlay)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(SupermuxUnreadBadgeStyle.rimOpacity),
                        lineWidth: style.rimWidth
                    )
            }
    }
}

/// The light-from-above wash over the badge's fill.
///
/// A white-to-black overlay rather than two pre-blended accent colors, because
/// the fill is caller-supplied (the Mac lets the user set a custom badge color)
/// and this shades whatever arrives without having to decompose it.
/// lint:allow namespace-enum — shared immutable gradient constants for SwiftUI and Core Graphics.
public enum SupermuxUnreadBadgeGradient {
    /// The wash, as SwiftUI stops.
    public static var overlay: LinearGradient {
        LinearGradient(
            stops: stops.map { stop in
                .init(color: stop.color, location: stop.location)
            },
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The wash as plain color/location pairs, so a non-SwiftUI renderer (the
    /// Mac's Core Graphics sidebar cell) draws the SAME gradient rather than a
    /// hand-matched approximation.
    public static var stops: [(color: Color, location: CGFloat)] {
        [
            (.white.opacity(SupermuxUnreadBadgeStyle.gradientTopLightening), 0),
            (.clear, CGFloat(SupermuxUnreadBadgeStyle.gradientMidpoint)),
            (.black.opacity(SupermuxUnreadBadgeStyle.gradientBottomDarkening), 1),
        ]
    }
}

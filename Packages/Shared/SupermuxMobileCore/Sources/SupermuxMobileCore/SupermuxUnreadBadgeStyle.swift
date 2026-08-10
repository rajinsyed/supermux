public import Foundation

/// The one description of the unread badge's shape, size and text, shared by
/// every surface that draws one on either platform.
///
/// The fork has THREE unread-badge renderers — the Mac's SwiftUI sidebar row,
/// the Mac's pure-AppKit sidebar row (behind the `appKitSidebarList` flag), and
/// the phone's workspace row — and before this type they disagreed on all of
/// it: the Mac drew a white count inside a fixed 16pt circle while the phone
/// drew a bare 11pt accent dot with no count at all. Two devices showing the
/// same workspace showed two different indicators.
///
/// This type is deliberately geometry-and-text only: no SwiftUI, no AppKit, no
/// color. Colors resolve differently per platform (`NSColor` vs `UIColor`
/// accent, per-window appearance on the Mac) and the AppKit renderer draws with
/// Core Graphics rather than views, so the platform files own painting. What
/// they must NOT own is the proportions — those live here and are unit-tested,
/// which is what actually keeps the two devices looking alike.
///
/// Everything is expressed as a multiple of the badge's own font size rather
/// than as absolute points, so the same style serves the Mac's dense 9pt
/// sidebar row and the phone's `.headline`-scale row without either becoming a
/// shrunken or bloated copy of the other.
public struct SupermuxUnreadBadgeStyle: Equatable, Sendable {
    /// Counts above this render as ``overflowText`` instead of a wide numeral,
    /// so a runaway workspace cannot stretch the badge across the row.
    public static let maximumDisplayedCount = 99

    /// What a count past ``maximumDisplayedCount`` reads as.
    ///
    /// The default remains the compact, fixed-glyph `99+` convention used by
    /// cmux's other numeric badges, while the package catalog keeps the visible
    /// marker localizable on every platform that renders this shared style.
    public static var overflowText: String {
        String(
            localized: "supermux.unreadBadge.overflow",
            defaultValue: "99+",
            bundle: .module
        )
    }

    /// Badge height as a multiple of the badge font size. A capsule this tall
    /// around a semibold numeral leaves the digit visually centered with room
    /// on both sides, and reproduces the Mac's existing 9pt-text-in-16pt-circle
    /// proportion that the sidebar was already tuned around.
    private static let heightRatio: CGFloat = 1.8

    /// Horizontal padding either side of the numeral, as a multiple of the font
    /// size. Only wide enough to matter once the count reaches two digits: at
    /// one digit ``minimumWidth`` keeps the capsule circular.
    private static let horizontalPaddingRatio: CGFloat = 0.42

    /// Hairline rim width as a multiple of the font size. The rim is what reads
    /// as "premium" rather than "flat sticker" on a dark sidebar; it is
    /// deliberately sub-pixel-thin at small sizes.
    private static let rimWidthRatio: CGFloat = 0.06

    /// Point size of the numeral.
    public let fontSize: CGFloat

    /// Creates a style around a badge font size.
    ///
    /// - Parameter fontSize: Point size of the numeral. Callers pass their own
    ///   surface's already-scaled size (the Mac multiplies by its sidebar font
    ///   scale; the phone by Dynamic Type), so this type never needs to know
    ///   which scaling regime it is under.
    public init(fontSize: CGFloat) {
        self.fontSize = max(1, fontSize)
    }

    /// Height of the capsule, and its minimum width — a single digit renders in
    /// a circle, exactly as the Mac's badge always has.
    public var height: CGFloat {
        (fontSize * Self.heightRatio).rounded()
    }

    /// Minimum capsule width, which keeps one-digit badges circular.
    public var minimumWidth: CGFloat { height }

    /// Padding either side of the numeral.
    public var horizontalPadding: CGFloat {
        (fontSize * Self.horizontalPaddingRatio).rounded()
    }

    /// Width of the hairline rim drawn inside the capsule's edge.
    public var rimWidth: CGFloat {
        max(0.5, fontSize * Self.rimWidthRatio)
    }

    /// Corner radius that makes the shape a true capsule.
    public var cornerRadius: CGFloat { height / 2 }

    /// The text to draw for a count, or `nil` when the badge should render as
    /// its countless dot form.
    ///
    /// `nil` is a real state, not a failure: a phone paired with an upstream
    /// cmux Mac receives `has_unread` with no count, and group headers roll
    /// their members up to a boolean. Those surfaces still have to say
    /// "something here is unread", so they draw the same capsule at
    /// ``dotDiameter`` with no numeral rather than inventing a number.
    ///
    /// - Parameter count: The unread count, or `nil` when only the fact of
    ///   unread activity is known.
    /// - Returns: The numeral, ``overflowText``, or `nil` for the dot form.
    public static func displayText(count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        guard count <= maximumDisplayedCount else { return overflowText }
        return String(count)
    }

    /// Edge length of the countless dot form. Smaller than a numeral badge
    /// because it carries less information and should not shout louder than
    /// the counted one sitting above it in the same list.
    public var dotDiameter: CGFloat {
        (height * 0.55).rounded()
    }

    /// Size of the badge for a count, including the dot form.
    ///
    /// - Parameters:
    ///   - count: The unread count, or `nil` for the dot form.
    ///   - textWidth: Measured width of ``displayText(count:)`` in the caller's
    ///     font. Ignored for the dot form. Callers that lay out with SwiftUI
    ///     can ignore this method entirely and let the capsule size itself;
    ///     it exists for the AppKit renderer, which computes frames by hand.
    /// - Returns: The badge's width and height.
    public func size(count: Int?, textWidth: CGFloat) -> CGSize {
        guard Self.displayText(count: count) != nil else {
            return CGSize(width: dotDiameter, height: dotDiameter)
        }
        return CGSize(
            width: max(minimumWidth, textWidth.rounded(.up) + horizontalPadding * 2),
            height: height
        )
    }
}

/// The badge's paint recipe, in plain numbers, so the three renderers that draw
/// it — SwiftUI on the Mac, Core Graphics on the Mac's AppKit sidebar, SwiftUI
/// on the phone — cannot drift into three different-looking badges.
///
/// A flat accent circle is what the badge used to be, and it reads as a sticker
/// pasted onto the row. What makes it read as part of the app instead is depth
/// that survives at 16pt: a barely-there vertical gradient so the capsule
/// catches light from above, a hairline inner rim that defines its edge against
/// both dark and light sidebars, and a tight accent-tinted shadow that lifts it
/// off the row without smearing. Every value here is deliberately small — at
/// this size anything stronger becomes mud.
extension SupermuxUnreadBadgeStyle {
    /// How much lighter the top of the capsule is than its base accent color,
    /// as an additive brightness delta in 0...1.
    public static let gradientTopLightening: Double = 0.13

    /// How much darker the bottom of the capsule is than its base accent color.
    /// Smaller than the top lightening so the badge brightens overall rather
    /// than just tilting, which keeps it legible on a dark sidebar.
    public static let gradientBottomDarkening: Double = 0.07

    /// Where the gradient's lightening gives way to its darkening, as a
    /// fraction of the badge's height. Above the midpoint so the lit band reads
    /// as the top surface rather than splitting the capsule in half.
    ///
    /// Lives here with the opacities because all three renderers build the same
    /// three stops; a location that stayed in one renderer would be the exact
    /// value most likely to drift.
    public static let gradientMidpoint: Double = 0.55

    /// Opacity of the white hairline rim drawn just inside the capsule's edge.
    public static let rimOpacity: Double = 0.28

    /// Opacity of the accent-tinted drop shadow.
    public static let shadowOpacity: Double = 0.35

    /// Shadow blur radius as a multiple of the font size.
    private static let shadowRadiusRatio: CGFloat = 0.22

    /// Shadow vertical offset as a multiple of the font size.
    private static let shadowOffsetRatio: CGFloat = 0.1

    /// Blur radius of the drop shadow at this badge's size.
    public var shadowRadius: CGFloat { fontSize * Self.shadowRadiusRatio }

    /// Downward offset of the drop shadow at this badge's size.
    public var shadowOffsetY: CGFloat { fontSize * Self.shadowOffsetRatio }
}

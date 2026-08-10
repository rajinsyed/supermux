public import SwiftUI
public import SupermuxMobileCore
import AppKit

/// The Mac's unread badge: a capsule carrying the unread count, or a small
/// countless dot when only the fact of unread activity is known.
///
/// A thin wrapper over ``SupermuxUnreadBadgeContent``, which the phone renders
/// too — one view, so the two devices cannot drift. This exists as a named Mac
/// type only so the sidebar's call sites read in their own vocabulary; it adds
/// no rendering of its own.
///
/// What this replaced: a flat accent circle, which reads as a sticker pasted
/// onto the row. Depth that survives at 16pt is what makes it read as part of
/// the app instead — see `SupermuxUnreadBadgeStyle` for the values and why each
/// is deliberately small.
public struct SupermuxUnreadBadgeView: View {
    private let count: Int?
    private let fontSize: CGFloat
    private let fillColor: Color
    private let textColor: Color

    /// Creates a badge.
    /// - Parameters:
    ///   - count: The unread count. `nil` (or a non-positive value) renders the
    ///     countless dot instead of a numeral.
    ///   - fontSize: Point size of the numeral, already scaled by the caller's
    ///     sidebar font scale and global magnification. Every other dimension
    ///     derives from it.
    ///   - fillColor: Base capsule color; the gradient is applied over it.
    ///   - textColor: Numeral color.
    public init(
        count: Int?,
        fontSize: CGFloat,
        fillColor: Color,
        textColor: Color
    ) {
        self.count = count
        self.fontSize = fontSize
        self.fillColor = fillColor
        self.textColor = textColor
    }

    public var body: some View {
        SupermuxUnreadBadgeContent(
            count: count,
            fontSize: fontSize,
            fillColor: fillColor,
            textColor: textColor
        )
    }
}

extension SupermuxUnreadBadgeGradient {
    /// The shared wash as AppKit colors, for the Core Graphics renderer in the
    /// pure-AppKit sidebar list. Derived from ``stops`` rather than restated,
    /// so that list cannot drift from the SwiftUI badge.
    public static var appKitStops: [(color: NSColor, location: CGFloat)] {
        stops.map { stop in (NSColor(stop.color), stop.location) }
    }
}

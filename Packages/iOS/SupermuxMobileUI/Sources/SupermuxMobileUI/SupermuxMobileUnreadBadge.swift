public import SupermuxMobileCore
public import SwiftUI

/// The phone's unread badge — the accent-tinted binding of the shared
/// ``SupermuxUnreadBadgeContent``, which the Mac renders too. One view, so the
/// two devices cannot drift; this wrapper only supplies the phone's colors and
/// its accessibility posture.
///
/// This replaces the phone's old bare accent dot, which had no count at all
/// while the Mac showed one, and which sat in a permanently-reserved left
/// gutter — an empty column down the whole list for a dot most rows never drew.
/// Here the badge occupies space only when it renders.
public struct SupermuxMobileUnreadBadge: View {
    private let count: Int?
    @ScaledMetric(relativeTo: .headline) private var fontSize: CGFloat = 10

    /// Creates a badge.
    /// - Parameters:
    ///   - count: The unread count. `nil` or non-positive renders the countless
    ///     dot — which is what a phone paired with an upstream cmux Mac gets,
    ///     since upstream sends `has_unread` without a count.
    ///   - fontSize: Base point size of the numeral. It scales relative to the
    ///     headline text beside workspace badges, preserving Dynamic Type.
    public init(count: Int?, fontSize: CGFloat) {
        self.count = count
        self._fontSize = ScaledMetric(wrappedValue: fontSize, relativeTo: .headline)
    }

    public var body: some View {
        SupermuxUnreadBadgeContent(
            count: count,
            fontSize: fontSize,
            fillColor: .accentColor,
            textColor: .white
        )
        // Rows fold the unread state into their own combined accessibility
        // summary, so the badge itself stays silent rather than announcing a
        // bare number after the workspace name.
        .accessibilityHidden(true)
    }
}

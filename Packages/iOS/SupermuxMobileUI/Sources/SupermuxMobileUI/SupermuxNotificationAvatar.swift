public import SupermuxMobileCore
public import SwiftUI

/// The project avatar a notification row shows: the project's icon image when
/// one has been fetched, otherwise an accent-gradient chip carrying its SF
/// Symbol or initial.
///
/// Separate from ``SupermuxProjectAvatar`` (the Projects section's) because the
/// two have different data: that one takes a live ``SupermuxProjectRowSnapshot``
/// and owns an async icon fetch, while a notification carries only a frozen
/// ``SupermuxNotificationProject`` and must not issue a fetch per row — the feed
/// scrolls, and a per-row round trip is exactly the cost the feed's projection
/// was built to avoid.
///
/// So this view is **synchronous and read-only**: it paints whatever
/// ``SupermuxProjectIconImageCache`` already holds for the project (populated by
/// the Projects section the user has almost certainly already visited) and
/// otherwise draws the generated avatar. There is no loading state, because a
/// gradient chip with the right letter is a complete answer, not a placeholder.
public struct SupermuxNotificationAvatar: View {
    private let project: SupermuxNotificationProject
    private let size: CGFloat

    /// Creates a notification avatar.
    /// - Parameters:
    ///   - project: The frozen project snapshot the notification carries.
    ///   - size: Square edge length in points.
    public init(project: SupermuxNotificationProject, size: CGFloat = 30) {
        self.project = project
        self.size = size
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
    }

    private var accent: Color {
        let palette = SupermuxProjectAccentPalette(
            colorHex: project.colorHex,
            projectID: project.id
        )
        return Color(red: palette.red, green: palette.green, blue: palette.blue)
    }

    /// The already-decoded icon for this project, if the cache holds one for
    /// the exact etag the notification recorded. A stale etag misses on
    /// purpose: a gradient chip is better than a previous project's logo.
    private var icon: Image? {
        guard project.hasIconImage else { return nil }
        return SupermuxProjectIconImageCache.shared.image(
            for: SupermuxProjectIconIdentity(
                projectID: project.id,
                hasCustomIcon: true,
                iconETag: project.iconETag
            )
        )
    }

    public var body: some View {
        ZStack {
            if let icon {
                shape.fill(Color.primary.opacity(0.06))
                icon
                    .resizable()
                    .scaledToFill()
            } else {
                shape.fill(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                glyph
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    /// The symbol or initial, white on the accent with a soft shadow so a light
    /// palette entry (yellow, lime) keeps its glyph legible.
    @ViewBuilder
    private var glyph: some View {
        Group {
            if let symbol = project.iconSymbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
            } else {
                Text(project.avatarLetter)
                    .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
    }
}

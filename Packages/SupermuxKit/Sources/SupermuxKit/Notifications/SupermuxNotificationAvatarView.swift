public import AppKit
public import SupermuxMobileCore
public import SwiftUI

/// The avatar a notification row shows for its project: the project's icon
/// image when it has one, otherwise an accent-gradient chip carrying its SF
/// Symbol or its initial.
///
/// Distinct from ``SupermuxProjectAvatarView`` (the sidebar's) in two ways that
/// matter at this size: it fills with the project's *resolved* accent — derived
/// from the project id when unset, so an uncolored project is still
/// identifiable rather than one more gray square in a list of gray squares —
/// and it draws no border, because at row scale a hairline reads as a drawn
/// outline around every item.
///
/// Takes an immutable ``SupermuxNotificationProject`` snapshot plus an already
/// decoded image, never a store, so it is safe below a lazy-list boundary.
public struct SupermuxNotificationAvatarView: View {
    private let project: SupermuxNotificationProject
    private let image: NSImage?
    private let size: CGFloat

    /// Creates a notification avatar.
    /// - Parameters:
    ///   - project: The identity snapshot to draw.
    ///   - image: The project's decoded icon, when it has one.
    ///   - size: Square edge length in points.
    public init(project: SupermuxNotificationProject, image: NSImage?, size: CGFloat = 30) {
        self.project = project
        self.image = image
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

    public var body: some View {
        ZStack {
            if let image {
                // A repo logo carries its own color; a tinted plate behind it
                // reads muddy, so it gets a neutral surface instead.
                shape.fill(Color.primary.opacity(0.06))
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
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

    /// The symbol or initial, white on the accent with a soft shadow so a
    /// light palette entry (yellow, lime) keeps its glyph legible.
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

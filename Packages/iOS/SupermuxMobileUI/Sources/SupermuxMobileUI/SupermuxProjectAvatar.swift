import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The project avatar: a rounded gradient chip carrying, in order, the
/// project's fetched custom icon → its SF Symbol → the first letter of its
/// name.
///
/// The pre-redesign avatar filled a flat `accent.opacity(0.22)` plate and, for
/// the common uncolored project, tinted it `.secondary` — so a real Projects
/// list rendered as a stack of identical gray squares. Here the chip is filled
/// with the project's resolved ``SupermuxProjectAccent`` gradient (derived from
/// the project id when unset), matching how the app already draws Mac avatars,
/// so every project is identifiable at a glance with no configuration.
///
/// A custom icon is drawn on a plain surface rather than the gradient: repo
/// logos carry their own color and a tinted backing behind them reads muddy.
struct SupermuxProjectAvatar: View {
    let row: SupermuxProjectRowSnapshot
    let size: CGFloat
    let iconPNGData: @Sendable (_ projectID: String) async -> Data?

    @State private var customIcon: Image?

    /// Continuous-rounded-square, proportional to the chip (the desktop
    /// avatar's ratio, kept so the two read as the same object).
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    }

    private var accent: SupermuxProjectAccent { row.accent }

    var body: some View {
        ZStack {
            if let customIcon {
                shape.fill(Color.primary.opacity(0.06))
                customIcon
                    .resizable()
                    .scaledToFill()
            } else {
                shape.fill(accent.avatarGradient)
                glyph
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // A hairline inner edge keeps the chip from bleeding into the row
        // background in dark mode, where gradient and background can be close
        // in luminance.
        .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        .task(id: iconIdentity) {
            guard row.hasCustomIcon else {
                customIcon = nil
                return
            }
            guard let data = await iconPNGData(row.id) else { return }
            customIcon = Self.decodeImage(data)
        }
        .accessibilityHidden(true)
    }

    /// The symbol, or the name's first letter. White on the accent gradient —
    /// the same treatment the app's Mac avatars use — with a soft shadow so a
    /// light palette entry (yellow, lime) keeps its glyph legible.
    @ViewBuilder
    private var glyph: some View {
        Group {
            if let symbol = row.iconSymbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
            } else {
                Text(row.avatarLetter)
                    .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
    }

    /// The avatar's icon-refetch identity: only the fields that change which
    /// bytes must be fetched/decoded, so unrelated row churn (branch subtitle,
    /// expansion, counts, run state) never re-issues `project.icon`. The etag
    /// is included because a Mac-side icon replacement keeps `hasCustomIcon`
    /// true while moving the content — without it the stale icon would render
    /// forever.
    private var iconIdentity: SupermuxProjectIconIdentity {
        SupermuxProjectIconIdentity(
            projectID: row.id,
            hasCustomIcon: row.hasCustomIcon,
            iconETag: row.iconETag
        )
    }

    private static func decodeImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        nil
        #endif
    }
}

/// See ``SupermuxProjectAvatar/iconIdentity``. Internal (not private) so a
/// focused unit test can pin the equality semantics without a SwiftUI test
/// harness.
struct SupermuxProjectIconIdentity: Equatable {
    let projectID: String
    let hasCustomIcon: Bool
    /// The icon's content etag (`nil` while the wire doesn't surface one) —
    /// the signal that re-keys the fetch when the icon's BYTES change while
    /// `hasCustomIcon` stays `true`.
    let iconETag: String?
}

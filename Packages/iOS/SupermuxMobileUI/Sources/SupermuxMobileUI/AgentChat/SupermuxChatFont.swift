public import SwiftUI

/// Typography scale for the supermux agent-chat surface.
///
/// One prose family and one mono family, both Dynamic-Type scaled. Sizes are
/// slightly tighter than the SwiftUI defaults (body is 15pt, not 17pt) so a
/// phone-sized transcript fits meaningfully more content per screen without
/// reading as small — the same trade the remodex timeline makes.
public extension Font {
    /// Single source for prose body size; every other size is derived by eye
    /// from this one.
    static let supermuxChatBodyPointSize: CGFloat = 15

    // MARK: - Prose

    /// Agent prose and user prompts.
    static func supermuxChatBody(_ weight: Font.Weight = .regular) -> Font {
        Font.system(size: supermuxChatBodyPointSize, weight: weight)
    }

    /// Activity-row labels and card headers.
    static func supermuxChatSubheadline(_ weight: Font.Weight = .regular) -> Font {
        Font.system(size: 14, weight: weight)
    }

    /// Secondary metadata on cards.
    static func supermuxChatFootnote(_ weight: Font.Weight = .regular) -> Font {
        Font.system(size: 12, weight: weight)
    }

    /// Timestamps, counts, and status captions.
    static func supermuxChatCaption(_ weight: Font.Weight = .regular) -> Font {
        Font.system(size: 11, weight: weight)
    }

    /// The smallest chrome text (chevrons' companions, badge digits).
    static func supermuxChatCaption2(_ weight: Font.Weight = .regular) -> Font {
        Font.system(size: 10, weight: weight)
    }

    /// The empty-state headline.
    static func supermuxChatTitle(_ weight: Font.Weight = .regular) -> Font {
        Font.system(size: 20, weight: weight)
    }

    /// Markdown heading, by level.
    static func supermuxChatHeading(level: Int) -> Font {
        switch level {
        case 1: return Font.system(size: 19, weight: .semibold)
        case 2: return Font.system(size: 17, weight: .semibold)
        default: return Font.system(size: 15.5, weight: .semibold)
        }
    }

    // MARK: - Monospaced

    /// Code, diffs, shell output, and file paths.
    static func supermuxChatMono(
        size: CGFloat = 12,
        weight: Font.Weight = .regular
    ) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }
}

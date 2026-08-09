public import SwiftUI

/// One line of agent activity: glyph, tensed verb, target, chevron.
///
/// This is the transcript's most common row and the piece that most defines
/// the surface. It is deliberately **borderless** — no card, no fill, no
/// stroke — because a session is mostly tool calls, and boxing each one turns
/// the transcript into a wall of rectangles. Tense carries state (`Reading` vs
/// `Read`), so running rows need no spinner; only a failure earns a colored
/// badge.
public struct SupermuxChatActivityRow: View {
    private let symbolName: String
    private let phrase: SupermuxChatActivityPhrase
    private let isFailed: Bool
    private let showsDisclosure: Bool
    private let accessibilityID: String
    private let onTap: (() -> Void)?

    @Environment(\.supermuxChatTheme) private var theme

    /// Creates an activity row.
    ///
    /// - Parameters:
    ///   - symbolName: SF Symbol for the tool family.
    ///   - phrase: The tensed verb and its target.
    ///   - isFailed: Whether the invocation failed.
    ///   - showsDisclosure: Whether a chevron hints at a detail sheet.
    ///   - accessibilityID: Stable identity for UI automation.
    ///   - onTap: Opens the detail sheet; `nil` makes the row inert.
    public init(
        symbolName: String,
        phrase: SupermuxChatActivityPhrase,
        isFailed: Bool = false,
        showsDisclosure: Bool = true,
        accessibilityID: String,
        onTap: (() -> Void)? = nil
    ) {
        self.symbolName = symbolName
        self.phrase = phrase
        self.isFailed = isFailed
        self.showsDisclosure = showsDisclosure
        self.accessibilityID = accessibilityID
        self.onTap = onTap
    }

    public var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { content }
                    .buttonStyle(.plain)
                    .accessibilityHint(Self.detailHint)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(accessibilityLabel)
    }

    private var content: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)

            Text(phrase.verb)
                .font(.supermuxChatBody())
                .foregroundStyle(.secondary)
                + Text(phrase.target.isEmpty ? "" : " \(phrase.target)")
                .font(.supermuxChatBody())
                .foregroundStyle(.tertiary)

            if isFailed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.failure)
            }

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 1)
            }

            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        // Activity rows repaint on every streamed delta while a tool runs;
        // an implicit animation here makes the whole transcript flicker.
        .transaction { $0.animation = nil }
    }

    private var accessibilityLabel: String {
        var label = phrase.target.isEmpty ? phrase.verb : "\(phrase.verb) \(phrase.target)"
        if isFailed {
            label += ", " + String(
                localized: "supermux.chat.activity.failed.accessibility",
                defaultValue: "failed",
                bundle: .module
            )
        }
        return label
    }

    static let detailHint = String(
        localized: "supermux.chat.detail.hint",
        defaultValue: "Opens the full details",
        bundle: .module
    )
}

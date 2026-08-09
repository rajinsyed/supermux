public import SwiftUI

/// Label text with a light wave sweeping across the glyphs.
///
/// Used for the live "Working" summary instead of a spinner: a spinner says
/// *a thing is spinning*, whereas shimmering the words says *this sentence is
/// what is in progress*. Honors Reduce Motion by falling back to plain text.
public struct SupermuxChatShimmerText: View, Equatable {
    private let text: String
    private let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let bandWidth: CGFloat = 60
    private static let duration: TimeInterval = 1.65

    /// Creates shimmering text.
    ///
    /// - Parameters:
    ///   - text: The label to shimmer.
    ///   - font: The label's font.
    public init(text: String, font: Font = .footnote) {
        self.text = text
        self.font = font
    }

    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
    }

    public var body: some View {
        label
            .overlay {
                if !reduceMotion {
                    wave
                        .mask(label)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
    }

    private var wave: some View {
        GeometryReader { proxy in
            let travel = proxy.size.width + Self.bandWidth
            LinearGradient(colors: waveColors, startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.bandWidth)
                .offset(x: -Self.bandWidth)
                .blendMode(.plusLighter)
                .keyframeAnimator(initialValue: CGFloat.zero, repeating: true) { content, offset in
                    content.offset(x: offset)
                } keyframes: { _ in
                    LinearKeyframe(travel, duration: Self.duration)
                }
        }
    }

    /// A narrow clear → bright → clear band, so the sweep reads as a moving
    /// highlight rather than the whole label pulsing.
    private var waveColors: [Color] {
        let edge = colorScheme == .dark ? 0.18 : 0.12
        let peak = colorScheme == .dark ? 0.95 : 0.82
        return [
            .clear,
            .white.opacity(edge),
            .white.opacity(peak),
            .white.opacity(edge),
            .clear,
        ]
    }
}

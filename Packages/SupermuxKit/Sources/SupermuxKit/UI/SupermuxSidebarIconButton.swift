public import SwiftUI

/// A compact rounded icon button for sidebar rows (the project row's "new
/// worktree" plus, for instance): a single SF Symbol on a soft square tile
/// that brightens on hover and gives press feedback.
///
/// Stateless apart from its own hover flag, so it sits safely below the
/// sidebar's lazy-list snapshot boundary.
public struct SupermuxSidebarIconButton: View {
    private let systemName: String
    private let help: String
    private let fontScale: CGFloat
    private let action: () -> Void

    @State private var isHovered = false

    /// Tile edge at `fontScale == 1`, matching the worktree-count pill height.
    private static let baseTileSize: CGFloat = 18
    /// Glyph point size at `fontScale == 1`.
    private static let baseGlyphSize: CGFloat = 9.5

    /// Creates an icon button.
    /// - Parameters:
    ///   - systemName: SF Symbol to draw.
    ///   - help: Tooltip and accessibility label.
    ///   - fontScale: Sidebar font scale (cmux's `sidebar-font-size`).
    ///   - action: Runs on click.
    public init(
        systemName: String,
        help: String,
        fontScale: CGFloat = 1,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.fontScale = fontScale
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Self.baseGlyphSize * fontScale, weight: .bold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: Self.baseTileSize * fontScale, height: Self.baseTileSize * fontScale)
                .background(
                    RoundedRectangle(cornerRadius: 5 * fontScale, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.14 : 0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5 * fontScale, style: .continuous))
        }
        .buttonStyle(SupermuxPressEffectButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

public import SwiftUI

/// The small colored avatar shown next to a project: an SF Symbol when the
/// project sets one, otherwise the first letter of the project name.
public struct SupermuxProjectAvatarView: View {
    private let project: SupermuxProject
    private let size: CGFloat

    /// Creates an avatar.
    /// - Parameters:
    ///   - project: The project to represent.
    ///   - size: Square edge length in points.
    public init(project: SupermuxProject, size: CGFloat = 20) {
        self.project = project
        self.size = size
    }

    public var body: some View {
        let accent = SupermuxProjectColor.color(fromHex: project.colorHex)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill((accent ?? Color.secondary).opacity(accent == nil ? 0.18 : 0.22))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder((accent ?? Color.secondary).opacity(0.55), lineWidth: 1)
            if let symbol = project.iconSymbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(accent ?? Color.secondary)
            } else {
                Text(initialLetter)
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(accent ?? Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initialLetter: String {
        guard let first = project.name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }
}

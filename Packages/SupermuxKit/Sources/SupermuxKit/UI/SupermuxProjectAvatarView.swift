public import SwiftUI
public import AppKit

/// The small avatar shown next to a project. Precedence: the resolved icon image
/// wins (the user's custom icon when set, otherwise an auto-detected logo file
/// from the repository); otherwise the project's SF Symbol; otherwise the first
/// letter of the project name.
public struct SupermuxProjectAvatarView: View {
    private let project: SupermuxProject
    private let detectedIcon: NSImage?
    private let size: CGFloat

    /// Creates an avatar.
    /// - Parameters:
    ///   - project: The project to represent.
    ///   - detectedIcon: The resolved icon image — the user's custom icon when
    ///     set, otherwise a logo auto-detected from the project files — shown in
    ///     preference to the SF Symbol or letter when present.
    ///   - size: Square edge length in points.
    public init(project: SupermuxProject, detectedIcon: NSImage? = nil, size: CGFloat = 20) {
        self.project = project
        self.detectedIcon = detectedIcon
        self.size = size
    }

    public var body: some View {
        Group {
            if let icon = detectedIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else {
                symbolOrLetterAvatar
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The tinted rounded-square avatar carrying the project's SF Symbol, or its
    /// initial letter when no symbol is set.
    private var symbolOrLetterAvatar: some View {
        let accent = SupermuxProjectColor.color(fromHex: project.colorHex)
        return ZStack {
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
    }

    private var initialLetter: String {
        guard let first = project.name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }
}

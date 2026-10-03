import SwiftUI

/// A Mac's identity color on the phone: the same slot palette the shell's
/// workspace avatars use (`MachineAvatarColors`, first stop of each
/// gradient — keep the two in step), honoring the user's per-Mac override
/// (`palette:<n>` or `#RRGGBB`).
enum SupermuxMacAccent {
    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .mint, .indigo, .brown,
    ]

    /// The Mac's color.
    /// - Parameters:
    ///   - colorIndex: The shell's color slot, if assigned.
    ///   - customColor: The user's override, if any.
    static func color(colorIndex: Int?, customColor: String?) -> Color {
        if let customColor, !customColor.isEmpty {
            if customColor.hasPrefix("palette:"),
               let slot = Int(customColor.dropFirst("palette:".count)) {
                return color(slot: slot)
            }
            if let rgb = SupermuxAvatarRGB(hex: customColor) {
                return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }
        }
        guard let colorIndex else { return .secondary }
        return color(slot: colorIndex)
    }

    private static func color(slot: Int) -> Color {
        palette[((slot % palette.count) + palette.count) % palette.count]
    }
}

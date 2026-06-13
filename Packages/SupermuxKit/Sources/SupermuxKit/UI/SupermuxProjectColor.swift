public import SwiftUI

/// The piggycode-style 12-color palette for project accents.
public struct SupermuxProjectColor: Identifiable, Hashable, Sendable {
    /// Palette entry name shown in pickers (already localized at declaration).
    public let name: String
    /// Color as `#RRGGBB`.
    public let hex: String

    public var id: String { hex }

    /// The standard palette, mirroring piggycode's project colors.
    public static let palette: [SupermuxProjectColor] = [
        SupermuxProjectColor(name: "Red", hex: "#ef4444"),
        SupermuxProjectColor(name: "Orange", hex: "#f97316"),
        SupermuxProjectColor(name: "Yellow", hex: "#eab308"),
        SupermuxProjectColor(name: "Lime", hex: "#84cc16"),
        SupermuxProjectColor(name: "Green", hex: "#22c55e"),
        SupermuxProjectColor(name: "Teal", hex: "#14b8a6"),
        SupermuxProjectColor(name: "Cyan", hex: "#06b6d4"),
        SupermuxProjectColor(name: "Blue", hex: "#3b82f6"),
        SupermuxProjectColor(name: "Indigo", hex: "#6366f1"),
        SupermuxProjectColor(name: "Purple", hex: "#a855f7"),
        SupermuxProjectColor(name: "Pink", hex: "#ec4899"),
        SupermuxProjectColor(name: "Slate", hex: "#64748b"),
    ]

    /// Parses `#RRGGBB` into a SwiftUI color; `nil` for malformed input.
    /// - Parameter hex: A `#RRGGBB` string.
    public static func color(fromHex hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

public import SwiftUI

/// The 12-color palette for project accents: Tailwind CSS's stock 500-series
/// hues (MIT), the same de-facto standard palette piggycode picks project
/// colors from.
public struct SupermuxProjectColor: Identifiable, Hashable, Sendable {
    /// Palette entry name shown in pickers, tooltips, and VoiceOver labels.
    /// Localized at declaration via `String(localized:)` (the palette is a
    /// `static let`, so names resolve once per launch, which matches macOS's
    /// relaunch-on-locale-change behavior).
    public let name: String
    /// Color as `#RRGGBB`.
    public let hex: String

    public var id: String { hex }

    /// The standard palette — Tailwind's `-500` hex values.
    public static let palette: [SupermuxProjectColor] = [
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.red", defaultValue: "Red"),
            hex: "#ef4444"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.orange", defaultValue: "Orange"),
            hex: "#f97316"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.yellow", defaultValue: "Yellow"),
            hex: "#eab308"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.lime", defaultValue: "Lime"),
            hex: "#84cc16"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.green", defaultValue: "Green"),
            hex: "#22c55e"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.teal", defaultValue: "Teal"),
            hex: "#14b8a6"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.cyan", defaultValue: "Cyan"),
            hex: "#06b6d4"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.blue", defaultValue: "Blue"),
            hex: "#3b82f6"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.indigo", defaultValue: "Indigo"),
            hex: "#6366f1"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.purple", defaultValue: "Purple"),
            hex: "#a855f7"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.pink", defaultValue: "Pink"),
            hex: "#ec4899"
        ),
        SupermuxProjectColor(
            name: String(localized: "supermux.projectColor.slate", defaultValue: "Slate"),
            hex: "#64748b"
        ),
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

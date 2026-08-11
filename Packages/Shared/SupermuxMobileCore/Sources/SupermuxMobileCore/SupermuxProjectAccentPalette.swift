import Foundation

/// A project accent resolved to plain RGB, with no UI framework attached.
///
/// The same resolution has to run in four places that cannot share a UI layer:
/// SwiftUI on macOS, SwiftUI on iOS, AppKit when rasterizing a notification
/// avatar to PNG, and (eventually) a notification service extension. Keeping
/// the arithmetic here means all four agree on the color for a given project,
/// which is the entire point — an avatar that changes hue between the sidebar
/// and the lock screen reads as a bug.
public struct SupermuxProjectAccentPalette: Sendable, Equatable {
    /// The 12-color project palette (Tailwind's `-500` series), in the order
    /// the desktop and phone editors present it. Pinned by tests against
    /// `SupermuxProjectColor.palette` (macOS) and
    /// `SupermuxProjectStyle.colorPalette` (iOS).
    public static let hexes: [String] = [
        "#ef4444", // red
        "#f97316", // orange
        "#eab308", // yellow
        "#84cc16", // lime
        "#22c55e", // green
        "#14b8a6", // teal
        "#06b6d4", // cyan
        "#3b82f6", // blue
        "#6366f1", // indigo
        "#a855f7", // purple
        "#ec4899", // pink
        "#64748b", // slate
    ]

    /// The palette derived accents are drawn from: ``hexes`` minus the final
    /// slate entry, which reads as "no color" and would defeat the purpose of
    /// deriving one.
    public static let derivedHexes: [String] = Array(hexes.dropLast())

    /// Red component, `0...1`.
    public let red: Double
    /// Green component, `0...1`.
    public let green: Double
    /// Blue component, `0...1`.
    public let blue: Double
    /// Whether the accent came from the project's own `color_hex` rather than
    /// being derived from its id.
    public let isExplicit: Bool

    /// Resolves the accent for a project: its explicit `color_hex` when it has
    /// one, otherwise a stable color derived from its id.
    ///
    /// Deriving matters more than it sounds: a real projects file is
    /// overwhelmingly `color_hex: nil`, and falling back to one neutral gray
    /// turns a notification feed into a column of identical chips. Derivation
    /// gives every project a consistent identity with zero configuration, and
    /// the same repo keeps the same color forever.
    ///
    /// - Parameters:
    ///   - colorHex: The project's explicit `#RRGGBB` accent, if any. Malformed
    ///     values are ignored and fall through to derivation.
    ///   - projectID: The project's stable id, hashed to pick a derived slot.
    public init(colorHex: String?, projectID: String) {
        if let colorHex, let components = Self.components(fromHex: colorHex) {
            self.red = components.red
            self.green = components.green
            self.blue = components.blue
            self.isExplicit = true
            return
        }
        let palette = Self.derivedHexes
        let index = Self.slot(for: projectID, slotCount: palette.count)
        // The palette is a compile-time constant of valid six-digit hexes, so
        // the parse cannot fail; the mid-gray is a non-trapping backstop.
        let components = Self.components(fromHex: palette[index])
            ?? (red: 0.39, green: 0.45, blue: 0.55)
        self.red = components.red
        self.green = components.green
        self.blue = components.blue
        self.isExplicit = false
    }

    /// Parses `#RRGGBB` (with or without the `#`) into normalized components.
    /// Shorthand, alpha, and malformed input return `nil` so callers fall back
    /// rather than rendering a wrong color.
    /// - Parameter hex: The color string.
    public static func components(fromHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") {
            digits = digits.dropFirst()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A stable palette slot for `projectID`, spread evenly regardless of the
    /// palette's size.
    ///
    /// djb2 alone is unusable here: its multiplier `33 == 3 * 11` vanishes
    /// under any modulus sharing a factor with it, so an 11- or 12-slot palette
    /// collapses to (nearly) the id's last character. The splitmix64 finalizer
    /// avalanches the low bits `% slotCount` actually reads, so the spread no
    /// longer depends on the palette size being coprime with 33. This mirrors
    /// `SupermuxProjectAccent.slot(for:slotCount:)` on iOS exactly — the two
    /// must agree or a project's phone and Mac avatars differ.
    ///
    /// - Parameters:
    ///   - projectID: The project's stable id.
    ///   - slotCount: Number of colors to choose between.
    public static func slot(for projectID: String, slotCount: Int) -> Int {
        var hash: UInt64 = 5381
        for scalar in projectID.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        hash ^= hash >> 30
        hash = hash &* 0xbf58_476d_1ce4_e5b9
        hash ^= hash >> 27
        hash = hash &* 0x94d0_49bb_1331_11eb
        hash ^= hash >> 31
        return Int(hash % UInt64(max(1, slotCount)))
    }

    /// This accent as `#RRGGBB`, for call sites that round-trip through a
    /// string (the push payload, the wire DTOs).
    public var hex: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

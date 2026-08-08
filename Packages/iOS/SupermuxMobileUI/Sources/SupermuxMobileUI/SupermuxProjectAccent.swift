public import SwiftUI

/// A project's resolved accent: the color its avatar, indent guide, and
/// status chips are tinted with.
///
/// The desktop lets a project carry an explicit `color_hex`, but in practice
/// most projects never get one — a real projects file is overwhelmingly
/// `color_hex: null`. Falling back to a single neutral gray (the pre-redesign
/// behavior) turned a long Projects list into a column of identical chips with
/// no way to tell one repo from another at a glance.
///
/// So an unconfigured project derives a STABLE accent from its own id instead:
/// the same repo keeps the same color forever, adjacent repos read apart, and
/// the list looks deliberate with zero configuration. An explicit `color_hex`
/// always wins — deriving is the fallback, never an override.
///
/// Pure value logic, so the derivation is unit-testable without SwiftUI.
///
/// **Why this does not call `MachineAvatarPalette.slot(machineID:fallbackID:)`.**
/// That resolver returns a raw `djb2 % slotCount`, and djb2's multiplier is
/// `33 == 3 * 11`. For any slot count sharing a factor with 33 the multiply
/// vanishes under the modulus and the hash degenerates to (nearly) its last
/// character alone. This palette is exactly that bad case: at 11 slots every
/// project whose id ends the same way lands on ONE color, and at 12 slots on
/// four. Measured over 40 realistic ids: 11 slots → 1 distinct color, 12 → 4,
/// while 8/10/16 → 8/10/13. Since this palette's size is a design choice that
/// may change again, the id is mixed through an avalanche finalizer first, so
/// the spread no longer depends on the palette's size being coprime with 33.
/// ``MachineAvatarPalette`` stays correct for its own 8-slot use.
public struct SupermuxProjectAccent: Equatable, Sendable {
    /// The palette used for derived accents: the pinned desktop-mirroring
    /// 12-color project palette, minus the last entry (slate), which reads as
    /// "no color" and would undo the point of deriving one.
    static var derivedPalette: [SupermuxAvatarRGB] {
        SupermuxProjectStyle.colorPalette
            .dropLast()
            .compactMap { SupermuxAvatarRGB(hex: $0.hex) }
    }

    /// The accent's RGB components.
    public let rgb: SupermuxAvatarRGB
    /// Whether this accent came from the project's own `color_hex` (`true`)
    /// or was derived from its id (`false`). Callers that want to treat an
    /// explicit choice more prominently can branch on this; the default
    /// rendering treats both identically.
    public let isExplicit: Bool

    /// Resolves a project's accent.
    ///
    /// - Parameters:
    ///   - explicitRGB: The parsed `color_hex`, when the project carries one.
    ///   - projectID: The project's stable id, used to derive an accent when
    ///     `explicitRGB` is `nil`.
    public init(explicitRGB: SupermuxAvatarRGB?, projectID: String) {
        if let explicitRGB {
            self.rgb = explicitRGB
            self.isExplicit = true
            return
        }
        let palette = Self.derivedPalette
        guard !palette.isEmpty else {
            // Unreachable while the pinned palette is non-empty; degrade to a
            // mid gray rather than trapping on an index.
            self.rgb = SupermuxAvatarRGB(hex: "#64748b") ?? SupermuxAvatarRGB(hex: "#808080")!
            self.isExplicit = false
            return
        }
        self.rgb = palette[Self.slot(for: projectID, slotCount: palette.count)]
        self.isExplicit = false
    }

    /// A stable palette slot for `projectID`, spread evenly regardless of how
    /// many colors the palette holds. See the type's note on why the shared
    /// `MachineAvatarPalette` resolver is unsuitable at this palette size.
    ///
    /// - Parameters:
    ///   - projectID: The project's stable id.
    ///   - slotCount: Number of colors to choose between.
    static func slot(for projectID: String, slotCount: Int) -> Int {
        var hash: UInt64 = 5381
        for scalar in projectID.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        // splitmix64 finalizer: avalanches the low bits that `% slotCount`
        // reads, so a slot count sharing a factor with djb2's 33 no longer
        // collapses the distribution.
        hash ^= hash >> 30
        hash = hash &* 0xbf58_476d_1ce4_e5b9
        hash ^= hash >> 27
        hash = hash &* 0x94d0_49bb_1331_11eb
        hash ^= hash >> 31
        return Int(hash % UInt64(max(1, slotCount)))
    }

    /// The accent as a SwiftUI color.
    public var color: Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// The avatar's fill: a soft two-stop wash of the accent, matching the
    /// app's machine-avatar treatment (`.topLeading → .bottomTrailing`) so a
    /// project chip and a Mac chip read as the same family of object.
    public var avatarGradient: LinearGradient {
        LinearGradient(
            colors: [color, color.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension SupermuxProjectRowSnapshot {
    /// This row's resolved accent (explicit `color_hex`, else derived from the
    /// project id).
    public var accent: SupermuxProjectAccent {
        SupermuxProjectAccent(explicitRGB: avatarRGB, projectID: id)
    }
}

import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// The accent resolution behind the redesigned project avatar: an explicit
/// `color_hex` always wins, and an unconfigured project derives a STABLE,
/// non-neutral accent from its id so a real (overwhelmingly uncolored)
/// projects list still reads as distinct rows.
@Suite struct SupermuxProjectAccentTests {
    private func dto(
        id: String = "11111111-1111-1111-1111-111111111111",
        name: String = "Alpha",
        colorHex: String? = nil
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: id,
            name: name,
            rootPath: "/Users/dev/\(name.lowercased())",
            colorHex: colorHex
        )
    }

    @Test func explicitColorWins() throws {
        let accent = SupermuxProjectAccent(
            explicitRGB: SupermuxAvatarRGB(hex: "#3B82F6"),
            projectID: "any-id"
        )
        #expect(accent.isExplicit)
        #expect(accent.rgb == SupermuxAvatarRGB(hex: "#3B82F6"))
    }

    @Test func unconfiguredProjectStillGetsAnAccent() {
        let accent = SupermuxProjectAccent(explicitRGB: nil, projectID: "some-project")
        #expect(!accent.isExplicit)
        // The whole point: it must NOT fall back to a single neutral.
        #expect(SupermuxProjectAccent.derivedPalette.contains(accent.rgb))
    }

    @Test func derivationIsStableForTheSameProject() {
        let first = SupermuxProjectAccent(explicitRGB: nil, projectID: "stable-id")
        let second = SupermuxProjectAccent(explicitRGB: nil, projectID: "stable-id")
        #expect(first.rgb == second.rgb)
    }

    @Test func derivationSpreadsAcrossThePalette() {
        // The real failure mode is every project landing on one color. Use the
        // shape of real ids (uuid-like) and require a healthy spread.
        let ids = (0..<40).map { "project-\($0)-a1b2c3d4" }
        var distinct: [SupermuxAvatarRGB] = []
        for id in ids {
            let rgb = SupermuxProjectAccent(explicitRGB: nil, projectID: id).rgb
            if !distinct.contains(rgb) {
                distinct.append(rgb)
            }
        }
        let summary = "derived accents collapsed onto \(distinct.count) colors across 40 ids"
        #expect(distinct.count >= 6, Comment(rawValue: summary))
    }

    @Test func slotSpreadSurvivesPaletteSizesThatShareAFactorWithDjb2() {
        // Regression: a raw `djb2 % slotCount` collapses whenever slotCount
        // shares a factor with djb2's multiplier 33 (== 3 * 11) — at 11 slots
        // the multiply vanishes entirely and every id with the same last
        // character lands on one color. Guard every plausible palette size,
        // not just today's.
        let ids = (0..<60).map { "project-\($0)-a1b2c3d4" }
        for slotCount in [3, 6, 8, 11, 12, 22, 33] {
            var distinct: [Int] = []
            for id in ids {
                let slot = SupermuxProjectAccent.slot(for: id, slotCount: slotCount)
                #expect(slot >= 0 && slot < slotCount)
                if !distinct.contains(slot) {
                    distinct.append(slot)
                }
            }
            let wanted = min(slotCount, 5)
            let summary = "slotCount \(slotCount) spread onto only \(distinct.count) slots"
            #expect(distinct.count >= wanted, Comment(rawValue: summary))
        }
    }

    @Test func derivedPaletteExcludesTheNeutralSlate() {
        // Slate is the palette's "no color" reading; deriving it would defeat
        // the purpose of deriving at all.
        let slate = SupermuxAvatarRGB(hex: "#64748b")
        #expect(!SupermuxProjectAccent.derivedPalette.contains(where: { $0 == slate }))
        #expect(SupermuxProjectAccent.derivedPalette.count == 11)
    }

    @Test func rowSnapshotResolvesItsOwnAccent() {
        let configured = SupermuxProjectRowSnapshot(project: dto(colorHex: "#22C55E"))
        #expect(configured.accent.isExplicit)
        #expect(configured.accent.rgb == SupermuxAvatarRGB(hex: "#22C55E"))

        let bare = SupermuxProjectRowSnapshot(project: dto(colorHex: nil))
        #expect(!bare.accent.isExplicit)
    }

    @Test func malformedColorHexFallsBackToDerivation() {
        // A garbage color_hex must not produce a neutral chip; the row's
        // avatarRGB is already nil for malformed input, so it derives.
        let row = SupermuxProjectRowSnapshot(project: dto(colorHex: "not-a-color"))
        #expect(!row.accent.isExplicit)
        #expect(SupermuxProjectAccent.derivedPalette.contains(row.accent.rgb))
    }
}

import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// Pure snapshot-mapping logic: DTO → row snapshot fields, the letter-avatar
/// derivation, the `#RRGGBB` color parsing, and the reserved count fields.
@Suite struct SupermuxProjectRowSnapshotTests {
    private func dto(
        name: String = "Alpha",
        colorHex: String? = "#3B82F6",
        iconSymbol: String? = "folder",
        hasCustomIcon: Bool? = true
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: "11111111-1111-1111-1111-111111111111",
            name: name,
            rootPath: "/Users/dev/alpha",
            colorHex: colorHex,
            iconSymbol: iconSymbol,
            hasCustomIcon: hasCustomIcon,
            defaultBranch: "main"
        )
    }

    @Test func mapsIdentityAndDisplayFields() {
        let row = SupermuxProjectRowSnapshot(project: dto())
        #expect(row.id == "11111111-1111-1111-1111-111111111111")
        #expect(row.name == "Alpha")
        #expect(row.rootPath == "/Users/dev/alpha")
        #expect(row.iconSymbol == "folder")
        #expect(row.hasCustomIcon == true)
        #expect(row.defaultBranch == "main")
    }

    @Test func countsAreReservedUntilLaterMilestonesFillThem() {
        // §6 workspace augmentation / m1-f5 worktrees supply the real values;
        // until then the badges stay hidden (nil), never zero.
        let row = SupermuxProjectRowSnapshot(project: dto())
        #expect(row.worktreeCount == nil)
        #expect(row.openWorkspaceCount == nil)
    }

    @Test func avatarLetterIsTheFirstGraphemeUppercased() {
        #expect(SupermuxProjectRowSnapshot(project: dto(name: "cmux")).avatarLetter == "C")
        #expect(SupermuxProjectRowSnapshot(project: dto(name: " supermux")).avatarLetter == "S")
        #expect(SupermuxProjectRowSnapshot(project: dto(name: "日本語")).avatarLetter == "日")
        #expect(SupermuxProjectRowSnapshot(project: dto(name: "")).avatarLetter == "?")
        #expect(SupermuxProjectRowSnapshot(project: dto(name: "   ")).avatarLetter == "?")
    }

    @Test func missingCustomIconFlagMeansNoFetch() {
        #expect(SupermuxProjectRowSnapshot(project: dto(hasCustomIcon: nil)).hasCustomIcon == false)
        #expect(SupermuxProjectRowSnapshot(project: dto(hasCustomIcon: false)).hasCustomIcon == false)
    }

    @Test func parsesSixDigitHexColorsWithOrWithoutHash() throws {
        let parsed = try #require(SupermuxAvatarRGB(hex: "#3B82F6"))
        #expect(abs(parsed.red - Double(0x3B) / 255) < 0.0001)
        #expect(abs(parsed.green - Double(0x82) / 255) < 0.0001)
        #expect(abs(parsed.blue - Double(0xF6) / 255) < 0.0001)

        #expect(SupermuxAvatarRGB(hex: "3b82f6") != nil)
        #expect(SupermuxAvatarRGB(hex: "#FFFFFF") == SupermuxAvatarRGB(hex: "ffffff"))
    }

    @Test func rejectsMalformedHexColors() {
        #expect(SupermuxAvatarRGB(hex: "") == nil)
        #expect(SupermuxAvatarRGB(hex: "#fff") == nil)
        #expect(SupermuxAvatarRGB(hex: "#12345") == nil)
        #expect(SupermuxAvatarRGB(hex: "#1234567") == nil)
        #expect(SupermuxAvatarRGB(hex: "#zzzzzz") == nil)
    }

    @Test func rowsAreCollapsedWithNoNestedWorktreesByDefault() {
        // The inline-nesting fields (m6-f1) default to the collapsed,
        // no-data state so pre-existing projections stay unchanged.
        let row = SupermuxProjectRowSnapshot(project: dto())
        #expect(row.isExpanded == false)
        #expect(row.nestedWorktrees == SupermuxProjectNestedWorktrees.unavailable)
    }

    @Test func unopenedNestedWorktreeRowsExcludeOpenWorktrees() {
        // The mac sidebar's disclosure lists only worktrees WITHOUT an open
        // workspace (open ones already render as nested workspace rows).
        let rows = SupermuxWorktreeRowSnapshot.unopenedRows(from: [
            SupermuxWorktreeDTO(path: "/w/opened", branch: "opened", isOpen: true, workspaceId: "ws-1"),
            SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false),
            SupermuxWorktreeDTO(path: "/w/unknown", branch: "unknown"),
        ])
        // `is_open` nil (older Mac) degrades to "not open" — the row stays
        // reachable rather than vanishing.
        #expect(rows.map(\.path) == ["/w/loose", "/w/unknown"])
    }

    @Test func rowColorComesFromTheDTOHex() {
        let row = SupermuxProjectRowSnapshot(project: dto(colorHex: "#3B82F6"))
        #expect(row.avatarRGB == SupermuxAvatarRGB(hex: "#3B82F6"))
        let plain = SupermuxProjectRowSnapshot(project: dto(colorHex: nil))
        #expect(plain.avatarRGB == nil)
        let malformed = SupermuxProjectRowSnapshot(project: dto(colorHex: "nope"))
        #expect(malformed.avatarRGB == nil)
    }
}

import Foundation
@testable import SupermuxMobileUI
import Testing

/// The editor's style pickers mirror the desktop exactly: the color palette
/// carries the same 12 hex values as `SupermuxProjectColor.palette`
/// (SupermuxKit is Mac-only, so the values are mirrored and pinned here),
/// and the curated symbol grid stays valid.
@Suite struct SupermuxProjectStyleTests {
    @Test func paletteMirrorsTheDesktopTwelveColors() {
        #expect(SupermuxProjectStyle.colorPalette.map(\.hex) == [
            "#ef4444", // Red
            "#f97316", // Orange
            "#eab308", // Yellow
            "#84cc16", // Lime
            "#22c55e", // Green
            "#14b8a6", // Teal
            "#06b6d4", // Cyan
            "#3b82f6", // Blue
            "#6366f1", // Indigo
            "#a855f7", // Purple
            "#ec4899", // Pink
            "#64748b", // Slate
        ])
    }

    @Test func paletteEntriesHaveLocalizedNonEmptyNames() {
        for entry in SupermuxProjectStyle.colorPalette {
            #expect(!entry.name.isEmpty)
        }
    }

    @Test func curatedSymbolsAreUniqueAndNonEmpty() {
        let symbols = SupermuxProjectStyle.iconSymbols
        #expect(!symbols.isEmpty)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }

    @Test func symbolChoicesAppendAnUnknownCurrentSymbolSoItStaysSelectable() {
        let choices = SupermuxProjectStyle.symbolChoices(including: "moon.stars")
        #expect(choices.last == "moon.stars")
        #expect(choices.dropLast() == SupermuxProjectStyle.iconSymbols[...])

        let curated = SupermuxProjectStyle.symbolChoices(including: SupermuxProjectStyle.iconSymbols[0])
        #expect(curated == SupermuxProjectStyle.iconSymbols)

        #expect(SupermuxProjectStyle.symbolChoices(including: nil) == SupermuxProjectStyle.iconSymbols)
    }
}

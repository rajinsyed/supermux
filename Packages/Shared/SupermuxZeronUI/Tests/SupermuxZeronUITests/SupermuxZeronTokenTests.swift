import SwiftUI
import Testing
@testable import SupermuxZeronUI

/// Resolves a `Color` back to the `#RRGGBB` + alpha it was authored with.
///
/// `Color.resolve(in:)` returns sRGB components for a `Color(.sRGB, …)`
/// literal, so the round trip is exact for every token in the table.
private struct ResolvedToken: Equatable, CustomStringConvertible {
    let hex: UInt32
    /// Rounded to 4 dp so `Float` storage noise cannot fail an exact compare,
    /// while still separating the values the design system distinguishes
    /// (the closest pair in the table is 0.10 vs 0.1080).
    let alpha: Double
    /// The unrounded resolved alpha, for threshold assertions.
    let rawAlpha: Double

    init(_ color: Color) {
        let r = color.resolve(in: EnvironmentValues())
        func channel(_ v: Float) -> UInt32 { UInt32((Double(v) * 255).rounded()) }
        hex = channel(r.red) << 16 | channel(r.green) << 8 | channel(r.blue)
        rawAlpha = Double(r.opacity)
        alpha = (rawAlpha * 10000).rounded() / 10000
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hex == rhs.hex && lhs.alpha == rhs.alpha
    }

    var description: String { String(format: "#%06X @%.4f", hex, alpha) }
}

private func expectToken(
    _ color: Color,
    _ hex: UInt32,
    _ alpha: Double = 1,
    _ name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let got = ResolvedToken(color)
    let want = ResolvedToken(.zeron(hex, alpha))
    #expect(got == want, "\(name): got \(got), want \(want)", sourceLocation: sourceLocation)
}

struct SupermuxZeronTokenTests {
    // MARK: - Palette spot checks (plan §1.2)

    @Test("dark palette spot check")
    func darkPaletteSpotCheck() {
        let t = SupermuxZeronTheme.dark
        expectToken(t.bg, 0x060606, 1, "bg")
        expectToken(t.surface, 0x0D0D0D, 1, "surface")
        expectToken(t.surfaceRaisedHover, 0x2B2B2B, 1, "surfaceRaisedHover")
        expectToken(t.text, 0xE5E5E5, 1, "text")
        expectToken(t.textFaint, 0x737373, 1, "textFaint")
        expectToken(t.accent, 0x7C86FF, 1, "accent")
        expectToken(t.warning, 0xFFB900, 1, "warning")
        expectToken(t.busy, 0xFB64B6, 1, "busy")
        expectToken(t.border, 0xFFFFFF, 0.08, "border")
        expectToken(t.codeText, 0xC4B4FF, 1, "codeText")
        expectToken(t.codeWash, 0xA684FF, 0.12, "codeWash")
        expectToken(t.diffHunkBG, 0x7592BD, 0.05, "diffHunkBG")
    }

    @Test("light palette spot check")
    func lightPaletteSpotCheck() {
        let t = SupermuxZeronTheme.light
        expectToken(t.bg, 0xFFFFFF, 1, "bg")
        expectToken(t.surface, 0xF4F4F4, 1, "surface")
        // §0.3 C5: #DEDEDE = neutral(0.900), not the 07-spec's #E0E0E0.
        expectToken(t.surfaceRaisedHover, 0xDEDEDE, 1, "surfaceRaisedHover")
        expectToken(t.text, 0x222222, 1, "text")
        expectToken(t.textFaint, 0x6D6D6D, 1, "textFaint")
        expectToken(t.accent, 0x4F39F6, 1, "accent")
        expectToken(t.warning, 0xBB4D00, 1, "warning")
        expectToken(t.busy, 0xE60076, 1, "busy")
        expectToken(t.border, 0x000000, 0.10, "border")
        // §0.3 C2/C4: violet-700 / violet-600, not #6e11b0 / #8200db.
        expectToken(t.codeText, 0x7008E7, 1, "codeText")
        expectToken(t.codeWash, 0x7F22FE, 0.10, "codeWash")
        expectToken(t.diffHunkBG, 0x3A5378, 0.07, "diffHunkBG")
    }

    @Test("onAccent is neutral(0.985) in both appearances")
    func onAccentIsAppearanceIndependent() {
        expectToken(SupermuxZeronTheme.dark.onAccent, 0xFAFAFA, 1, "dark onAccent")
        expectToken(SupermuxZeronTheme.light.onAccent, 0xFAFAFA, 1, "light onAccent")
    }

    // MARK: - Ink helper rules (plan §1.2)

    /// The rule the plan calls out explicitly: hairlines scale by 1.35 (capped
    /// at 0.5) in light mode; fills scale by exactly 1.0. Halving the fill
    /// alphas once erased the composer plate entirely, so `INK_FILL_SCALE` is
    /// deliberately 1.0 and only the TONE flips.
    @Test("light_hairline_scales_but_fills_do_not")
    func lightHairlineScalesButFillsDoNot() {
        #expect(ZeronInk.fillScale == 1.00)
        #expect(ZeronInk.hairlineScale == 1.35)

        for a in [0.02, 0.03, 0.055, 0.08, 0.10, 0.16] {
            // Fills: same alpha, flipped tone.
            expectToken(ZeronInk.ink(a, dark: true), 0xFFFFFF, a, "ink(\(a)) dark")
            expectToken(ZeronInk.ink(a, dark: false), 0x000000, a, "ink(\(a)) light")

            // Washes: same alpha, soft-white ↔ soft-black tone (not pure).
            expectToken(ZeronInk.wash(a, dark: true), 0xEBEBEB, a, "wash(\(a)) dark")
            expectToken(ZeronInk.wash(a, dark: false), 0x1A1A1A, a, "wash(\(a)) light")

            // Hairlines: light gets MORE ink so a 1 pt edge survives a bright field.
            expectToken(ZeronInk.hairline(a, dark: true), 0xFFFFFF, a, "hairline(\(a)) dark")
            expectToken(
                ZeronInk.hairline(a, dark: false),
                0x000000,
                a * 1.35,
                "hairline(\(a)) light"
            )
        }

        // The 0.5 cap: 0.60 × 1.35 = 0.81 would be opaque-looking; it clamps.
        expectToken(ZeronInk.hairline(0.60, dark: false), 0x000000, 0.5, "hairline(0.6) capped")
        expectToken(ZeronInk.hairline(0.45, dark: false), 0x000000, 0.5, "hairline(0.45) capped")
        // Just below the cap boundary the scale still applies.
        expectToken(ZeronInk.hairline(0.30, dark: false), 0x000000, 0.405, "hairline(0.3) scaled")
    }

    /// The selection ring is an inset edge stroke, not a shadow, and light's
    /// ring is a FLAT 7 % — deliberately not `hairline(0.09)`, whose 0.1215
    /// outlined every selected chip in a dark box.
    @Test("selection_ring_is_edge_only")
    func selectionRingIsEdgeOnly() {
        let dark = SupermuxZeronTheme.dark
        let light = SupermuxZeronTheme.light

        expectToken(dark.selectionRing(), 0xFFFFFF, 0.09, "dark ring")
        expectToken(light.selectionRing(), 0x000000, 0.07, "light ring")

        // zeron's own assertion (`glass_selection_is_edge_only_and_subtle`):
        // the ring is subtle enough to read as an edge, never a plate.
        #expect(ResolvedToken(dark.selectionRing()).alpha <= 0.09)
        #expect(ResolvedToken(light.selectionRing()).alpha <= 0.09)

        // Light is FLAT, not hairline-scaled: 0.09 × 1.35 = 0.1215 outlined
        // every selected chip in a dark box.
        let hairlineScaled = ZeronInk.hairline(0.09, dark: false)
        #expect(abs(ResolvedToken(hairlineScaled).rawAlpha - 0.1215) <= 1e-4)
        #expect(ResolvedToken(light.selectionRing()) != ResolvedToken(hairlineScaled))

        // Hover and selection share the exact same FILL; only the ring differs.
        #expect(ResolvedToken(dark.glassSelectedBG()) == ResolvedToken(dark.glassHover()))
        #expect(ResolvedToken(light.cardSelectedBG()) == ResolvedToken(light.glassHover()))
        #expect(ResolvedToken(dark.selectionRing()) != ResolvedToken(dark.glassSelectedBG()))
    }

    // MARK: - Derived functions (plan §1.2)

    @Test("derived glass functions resolve to the specified values")
    func derivedFunctions() {
        let dark = SupermuxZeronTheme.dark
        let light = SupermuxZeronTheme.light

        expectToken(dark.glassHover(), 0xEBEBEB, 0.11, "dark glassHover")
        expectToken(light.glassHover(), 0x1A1A1A, 0.06, "light glassHover")
        expectToken(dark.glassOverlay(), 0x353535, 0.34, "dark glassOverlay")
        expectToken(light.glassOverlay(), 0xFFFFFF, 0.85, "light glassOverlay")

        // §0.3 C13: light pins 0.30 on BOTH platforms, never an opaque slab.
        expectToken(dark.inputGlassBG(), 0xFFFFFF, 0.03, "dark inputGlassBG")
        expectToken(light.inputGlassBG(), 0xFFFFFF, 0.30, "light inputGlassBG")

        expectToken(dark.cardGlassBG(), 0x0D0D0D, 0.40, "dark cardGlassBG")
        expectToken(light.cardGlassBG(), 0xF4F4F4, 0.40, "light cardGlassBG")

        // §0.3 C1: wash(0.08)/wash(0.04), NOT the screenshots' #1E1E1E.
        expectToken(dark.userBubbleBG(), 0xEBEBEB, 0.08, "dark userBubbleBG")
        expectToken(light.userBubbleBG(), 0x1A1A1A, 0.04, "light userBubbleBG")

        expectToken(dark.scrim(), 0x000000, 0.60, "dark scrim")
        expectToken(light.scrim(), 0x000000, 0.32, "light scrim")

        expectToken(dark.band, 0x000000, 0.16, "dark band")
        expectToken(light.band, 0x000000, 0.045, "light band")

        // §0.3 C7: diff row washes stay translucent so they can composite over
        // the chip card in the transcript and over `bg` in the changes pane.
        expectToken(dark.diffAddWash(), 0x00D492, 0.055, "dark diffAddWash")
        expectToken(light.diffDelWash(), 0xE7000B, 0.055, "light diffDelWash")
    }

    /// §0.3 C13: the SHELL is glass on macOS and opaque on iOS.
    @Test("isGlass follows the platform")
    func isGlassFollowsPlatform() {
        #if os(macOS)
        #expect(SupermuxZeronTheme.isGlassPlatform)
        expectToken(SupermuxZeronTheme.dark.glass(), 0x080808, 0.80, "dark glass")
        expectToken(SupermuxZeronTheme.light.glass(), 0xFAFAFA, 0.80, "light glass")
        #else
        #expect(!SupermuxZeronTheme.isGlassPlatform)
        expectToken(SupermuxZeronTheme.dark.glass(), 0x0D0D0D, 1, "dark glass (opaque)")
        expectToken(SupermuxZeronTheme.light.glass(), 0xF4F4F4, 1, "light glass (opaque)")
        #endif
    }

    /// The composited hexes the plan quotes as verification fixtures. This is
    /// what proves a translucent token is the right ONE, without ever letting a
    /// composite be baked into the token itself.
    @Test("translucent tokens composite to the plan's verification hexes")
    func compositeFixtures() {
        // Straight-alpha source-over in sRGB, exactly zeron's `flatten`.
        func flatten(_ fg: Color, over bg: Color) -> UInt32 {
            let f = fg.resolve(in: EnvironmentValues())
            let b = bg.resolve(in: EnvironmentValues())
            let a = Double(f.opacity)
            func mix(_ x: Float, _ y: Float) -> UInt32 {
                UInt32(((Double(x) * a + Double(y) * (1 - a)) * 255).rounded())
            }
            return mix(f.red, b.red) << 16 | mix(f.green, b.green) << 8 | mix(f.blue, b.blue)
        }

        let dark = SupermuxZeronTheme.dark
        #expect(flatten(dark.ink(0.03), over: dark.bg) == 0x0D0D0D, "chip card / composer pill")
        #expect(flatten(dark.ink(0.035), over: dark.bg) == 0x0F0F0F, "code-block body")
        #expect(flatten(dark.ink(0.08), over: dark.bg) == 0x1A1A1A, "guide rail")
        #expect(flatten(dark.userBubbleBG(), over: dark.bg) == 0x181818, "user bubble")
        #expect(flatten(dark.glassHover(), over: dark.bg) == 0x1F1F1F, "hover / selection fill")
        #expect(flatten(dark.codeWash, over: dark.bg) == 0x191524, "inline code wash")
        // NOTE: the plan §1.2 and spec 03 §0 both LABEL this composite
        // `#202020`, but spec 03 also records the measured screenshot pixel as
        // **33**, and 33 == 0x21. Re-sampling `group_zoom.png` confirms 33 is
        // the third-brightest flat fill in the frame. Exact source-over of
        // white @ 0.08 over `#0E0E0E` is 0x21 as well, so the `#202020` label
        // is an off-by-one transcription of its own citation. Both the source
        // recipe and the pixel agree on 0x21 — the token is `ink(0.08)`
        // regardless, so only this fixture changes.
        #expect(flatten(dark.ink(0.08), over: dark.surfaceCard) == 0x212121, "icon tile on card")
        #expect(flatten(dark.ink(0.06), over: dark.surfaceCard) == 0x1C1C1C, "chevron tile on card")
        #expect(flatten(dark.hairline(0.07), over: dark.surfaceCard) == 0x1F1F1F, "chip card border")
        #expect(flatten(dark.ink(0.06), over: dark.bg) == 0x151515, "group header chevron tile")

        let light = SupermuxZeronTheme.light
        #expect(flatten(light.userBubbleBG(), over: light.bg) == 0xF6F6F6, "light user bubble")
        #expect(flatten(light.glassHover(), over: light.bg) == 0xF1F1F1, "light hover fill")
    }

    // MARK: - Syntax palette (plan §1.3)

    @Test("every highlight kind maps to its family")
    func syntaxKindMapping() throws {
        for theme in [SupermuxZeronTheme.dark, .light] {
            let p = theme.syntax
            let expected: [SupermuxZeronHighlightKind: Color] = [
                .keyword: p.indigo, .function: p.indigo,
                .string: p.emerald, .typeBuiltin: p.emerald, .constant: p.emerald,
                .stringSpecial: p.pink, .escape: p.pink, .functionBuiltin: p.pink,
                .macro: p.pink, .variableSpecial: p.pink, .tag: p.pink,
                .number: p.amber, .boolean: p.amber, .type: p.amber,
                .constructor: p.amber, .property: p.amber, .attribute: p.amber,
                .label: p.amber,
                .variable: p.textTone, .parameter: p.textTone,
                .operator: p.textTone, .punctuation: p.textTone, .embedded: p.textTone,
                .comment: p.commentTone,
                .invalid: p.red,
            ]
            // Every kind is covered — no silent gap in the table.
            #expect(expected.count == SupermuxZeronHighlightKind.allCases.count)
            for kind in SupermuxZeronHighlightKind.allCases {
                let want = try #require(expected[kind])
                #expect(
                    ResolvedToken(p.color(for: kind)) == ResolvedToken(want),
                    "\(kind) in \(theme.isDark ? "dark" : "light")"
                )
            }
            // Embedded and Punctuation deliberately share one field.
            #expect(
                ResolvedToken(p.color(for: .embedded)) == ResolvedToken(p.color(for: .punctuation))
            )
        }
    }

    @Test("syntax hue families carry the git-graph-toned hexes")
    func syntaxFamilies() {
        let d = SupermuxZeronSyntaxPalette.dark
        expectToken(d.indigo, 0x8F96ED, 1, "dark indigo")
        expectToken(d.pink, 0xE679B4, 1, "dark pink")
        expectToken(d.emerald, 0x1EB787, 1, "dark emerald")
        expectToken(d.amber, 0xDBA924, 1, "dark amber")
        expectToken(d.red, 0xE9797C, 1, "dark red")
        expectToken(d.commentTone, 0x808080, 1, "dark comment")
        expectToken(d.textTone, 0xE5E5E5, 1, "dark text alias")

        let l = SupermuxZeronSyntaxPalette.light
        expectToken(l.indigo, 0x5754B4, 1, "light indigo")
        expectToken(l.pink, 0x8D2F58, 1, "light pink")
        expectToken(l.emerald, 0x0F5B41, 1, "light emerald")
        expectToken(l.amber, 0x7C451E, 1, "light amber")
        expectToken(l.red, 0xA61B20, 1, "light red")
        expectToken(l.commentTone, 0x5D5D5D, 1, "light comment")
        expectToken(l.textTone, 0x222222, 1, "light text alias")

        // The text and comment aliases skip git_graph_tone, so they equal the
        // theme's own text token exactly.
        #expect(ResolvedToken(d.textTone) == ResolvedToken(SupermuxZeronTheme.dark.text))
        #expect(ResolvedToken(l.textTone) == ResolvedToken(SupermuxZeronTheme.light.text))
    }
}

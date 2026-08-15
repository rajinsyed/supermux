import CoreText
import Foundation
import Testing
@testable import SupermuxZeronUI

/// Font registration is the one W0 failure that is invisible at runtime: a
/// silent fallback to a wider system face still renders, but every measured
/// width in the specs shifts and the analytic row heights stop matching the
/// content (plan R10).
struct SupermuxZeronFontTests {
    @Test("both PostScript names resolve from Bundle.module")
    func bothFacesRegister() {
        let diagnostic = SupermuxZeronFonts.diagnostic
        #expect(diagnostic.failures.isEmpty, "registration failures: \(diagnostic.failures)")
        #expect(diagnostic.sansResolved, "Geist-Regular did not resolve")
        #expect(diagnostic.monoResolved, "GeistMono-Regular did not resolve")
        #expect(diagnostic.isFullyRegistered)
        #expect(SupermuxZeronFonts.isRegistered)
    }

    @Test("the vendored faces and their license ship in the resource bundle")
    func resourcesArePresent() {
        for name in ["Geist", "GeistMono"] {
            #expect(
                Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") != nil,
                "\(name).ttf missing"
            )
        }
        // OFL 1.1 requires the license travel with the faces (plan §6.1).
        #expect(
            Bundle.module.url(forResource: "OFL", withExtension: "txt", subdirectory: "Fonts") != nil,
            "OFL.txt must ship next to the faces it licenses"
        )
    }

    /// A missing PostScript name does NOT return nil from CoreText — it
    /// substitutes. This asserts the check `resolvesToVendoredFace` performs is
    /// actually discriminating, so a future regression cannot pass vacuously.
    @Test("the resolution check rejects a substituted face")
    func substitutionIsDetected() {
        let bogus = CTFontCreateWithName("SupermuxZeron-NoSuchFace" as CFString, 14, nil)
        let resolved = CTFontCopyPostScriptName(bogus) as String
        #expect(resolved != "SupermuxZeron-NoSuchFace", "CoreText substitutes silently")
    }

    /// The whole reason weights go through named instances rather than
    /// `Font.weight(_:)`: a `kCTFontWeightTrait` descriptor over a variable
    /// face resolves back to Regular with the axis unapplied. The named
    /// instance applies it, which the glyph advance proves.
    @Test("named instances actually apply the wght axis")
    func namedInstancesApplyTheWeightAxis() throws {
        try #require(SupermuxZeronFonts.isRegistered)

        func advanceOfH(_ postScriptName: String) -> Double {
            let font = CTFontCreateWithName(postScriptName as CFString, 14, nil)
            #expect((CTFontCopyPostScriptName(font) as String) == postScriptName)
            var glyph = CTFontGetGlyphWithName(font, "H" as CFString)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            return advance.width
        }

        // Sans: heavier named instances are strictly wider.
        var previous = 0.0
        for weight in SupermuxZeronFontWeight.allCases {
            let name = SupermuxZeronFonts.postScriptName(
                base: SupermuxZeronFonts.sansPostScriptBase,
                weight: weight
            )
            let width = advanceOfH(name)
            #expect(width > previous, "\(name) is not wider than the step below it")
            previous = width
        }

        // Mono: every weight has the SAME advance, which is what makes it mono.
        let monoWidths = SupermuxZeronFontWeight.allCases.map {
            advanceOfH(
                SupermuxZeronFonts.postScriptName(
                    base: SupermuxZeronFonts.monoPostScriptBase,
                    weight: $0
                )
            )
        }
        let first = try #require(monoWidths.first)
        for width in monoWidths {
            #expect(abs(width - first) < 1e-6, "Geist Mono advances must be weight-invariant")
        }
    }

    @Test("the vendored faces carry the metrics the line-box math assumes")
    func faceMetrics() throws {
        try #require(SupermuxZeronFonts.isRegistered)
        typealias Metrics = SupermuxZeronFonts.Metrics

        #expect(Metrics.unitsPerEm == 1000)
        #expect(Metrics.hheaAscender == 1005)
        #expect(Metrics.hheaDescender == -295)
        #expect(Metrics.hheaLineGap == 0)
        #expect(Metrics.naturalLineHeightMultiple == 1.300)

        // (1005 + 295 + 0) / 1000 — the constant must match the binaries.
        let derived = (Metrics.hheaAscender - Metrics.hheaDescender + Metrics.hheaLineGap)
            / Metrics.unitsPerEm
        #expect(abs(derived - Metrics.naturalLineHeightMultiple) < 1e-9)

        for base in [SupermuxZeronFonts.sansPostScriptBase, SupermuxZeronFonts.monoPostScriptBase] {
            let name = SupermuxZeronFonts.postScriptName(base: base, weight: .regular)
            let font = CTFontCreateWithName(name as CFString, 14, nil)
            let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            #expect(
                abs(natural - Metrics.naturalLineHeight(forSize: 14)) < 0.01,
                "\(name) natural line height \(natural) != 18.2"
            )
        }

        // Body text is 14 pt in a fixed 22 pt markdown box, so the box carries
        // 3.8 pt of extra leading over the face's natural 18.2.
        let leading = Metrics.boxLeading(
            forSize: SupermuxZeronMetrics.Markdown.textSize,
            boxHeight: SupermuxZeronMetrics.Markdown.lineHeight
        )
        #expect(abs(leading - 3.8) < 0.01)
    }

    @Test("platform fonts resolve to the vendored faces and are cached")
    func platformFonts() throws {
        try #require(SupermuxZeronFonts.isRegistered)
        let sans = SupermuxZeronFonts.platformSans(size: 14, weight: .semibold)
        #expect(sans.fontName == "Geist-SemiBold")
        let mono = SupermuxZeronFonts.platformMono(size: 12.5)
        #expect(mono.fontName == "GeistMono-Regular")
        // The cache returns an equal font for a repeated key.
        #expect(SupermuxZeronFonts.platformSans(size: 14, weight: .semibold) == sans)
    }
}

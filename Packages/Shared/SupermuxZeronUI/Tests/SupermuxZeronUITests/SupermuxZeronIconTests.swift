//
//  SupermuxZeronIconTests.swift
//  SupermuxZeronUITests
//
//  Asset presence and drawing conventions for every `SupermuxZeronIcon.Name`.
//
//  These are FILE-LEVEL assertions on the resource bundle. Whether a glyph
//  renders as a tintable template is a property of the compiled `Assets.car`,
//  which only `actool` produces — SwiftPM copies `.xcassets` verbatim and never
//  invokes it, so a `swift test` run has no catalog to load an image from. That
//  half is verified in the `xcodebuild` leg.
//
//  The stroke-weight assertions are not pedantry. Solar Linear's 1.5-on-24
//  (0.0625 em) is the design's baseline weight; `check` at 1.6-on-16 is
//  deliberately 60 % heavier, and normalizing them would flatten a distinction
//  zeron makes on purpose (spec 08 §4.3).
//

import Foundation
import Testing

@testable import SupermuxZeronUI

@Suite("Zeron icon assets")
struct SupermuxZeronIconTests {
    private var catalog: URL {
        get throws {
            let resources = try #require(Bundle.supermuxZeronUI.resourceURL)
            return resources.appending(path: "Icons.xcassets")
        }
    }

    private func markup(for name: SupermuxZeronIcon.Name) throws -> String {
        let svg = try catalog
            .appending(path: "\(name.rawValue).imageset")
            .appending(path: "\(name.rawValue).svg")
        return try String(contentsOf: svg, encoding: .utf8)
    }

    @Test("Every enum case has a vendored imageset", arguments: SupermuxZeronIcon.Name.allCases)
    func everyCaseHasAnAsset(name: SupermuxZeronIcon.Name) throws {
        let imageset = try catalog.appending(path: "\(name.rawValue).imageset")
        #expect(
            FileManager.default.fileExists(atPath: imageset.path),
            "\(name.rawValue).imageset is missing — the enum case would render blank"
        )
        let svg = imageset.appending(path: "\(name.rawValue).svg")
        #expect(FileManager.default.fileExists(atPath: svg.path))
    }

    @Test(
        "Every imageset is a template-tinted vector",
        arguments: SupermuxZeronIcon.Name.allCases
    )
    func everyAssetIsTemplateTinted(name: SupermuxZeronIcon.Name) throws {
        let contents = try catalog
            .appending(path: "\(name.rawValue).imageset")
            .appending(path: "Contents.json")
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: contents)) as? [String: Any]
        )
        let properties = try #require(json["properties"] as? [String: Any])
        // Without `template`, `.foregroundStyle` cannot tint the glyph and every
        // chip icon paints in its authored color.
        #expect(properties["template-rendering-intent"] as? String == "template")
        // Without the vector representation the asset rasterizes at the
        // catalog's fixed scales and blurs at the 11 / 12.5 / 17 pt sizes the
        // design actually uses.
        #expect(properties["preserves-vector-representation"] as? Bool == true)

        let images = try #require(json["images"] as? [[String: Any]])
        #expect(images.contains { $0["filename"] as? String == "\(name.rawValue).svg" })
    }

    @Test(
        "Every glyph paints with currentColor and carries a real extent",
        arguments: SupermuxZeronIcon.Name.allCases
    )
    func everyGlyphIsCurrentColorAndSized(name: SupermuxZeronIcon.Name) throws {
        let svg = try markup(for: name)
        // gpui tints the whole SVG with the text color, which only works when
        // the glyph paints `currentColor`.
        #expect(svg.contains("currentColor"), "\(name.rawValue) is not currentColor")
        // `actool` derives an asset's intrinsic POINT size from width/height,
        // not from viewBox: zeron's `1em` compiles to a 1 × 1 pt image, and
        // every icon renders as a single point.
        #expect(!svg.contains("1em"), "\(name.rawValue) still carries a 1em extent")
        #expect(svg.contains("viewBox="))
    }

    @Test("The Solar Linear body keeps its 1.5-on-24 stroke")
    func solarLinearStrokeWeight() throws {
        // The 0.0625 em normalized weight — lighter than SF Symbols' .regular,
        // which is exactly why the set ships as vectors.
        let solar: [SupermuxZeronIcon.Name] = [
            .command, .document, .documentAdd, .pen, .magnifer, .folderWithFiles,
            .global, .checklist, .widget, .copy, .arrowUp, .arrowDown, .paperclip,
            .closeCircle, .dangerTriangle, .folder, .altArrowDown, .return, .star,
            .starBold, .list,
        ]
        for name in solar {
            let svg = try markup(for: name)
            #expect(
                svg.contains(#"viewBox="0 0 24 24""#),
                "\(name.rawValue) left the 24 grid"
            )
            #expect(
                svg.contains(#"stroke-width="1.5""#),
                "\(name.rawValue) left the 1.5 Solar Linear weight"
            )
        }
    }

    @Test("check is deliberately heavier: 1.6 on a 16 grid")
    func checkIsHeavier() throws {
        let svg = try markup(for: .check)
        #expect(svg.contains(#"viewBox="0 0 16 16""#))
        // 0.1000 em — 60 % heavier than the Solar body, on purpose.
        #expect(svg.contains(#"stroke-width="1.6""#))
    }

    @Test("git-branch is the hand-drawn 24-grid gap-filler, three node circles")
    func gitBranchIsHandDrawn() throws {
        let svg = try markup(for: .gitBranch)
        #expect(svg.contains(#"viewBox="0 0 24 24""#))
        #expect(svg.contains(#"stroke-width="1.5""#))
        // "the set has no branch icon" — zeron drew one in the Solar style with
        // three r=2.25 nodes. SF's `arrow.triangle.branch` has none.
        #expect(svg.components(separatedBy: #"r="2.25""#).count == 4)
    }

    @Test("star-bold is star's path, filled")
    func starBoldIsTheFilledStar() throws {
        let star = try markup(for: .star)
        let bold = try markup(for: .starBold)
        #expect(star.contains(#"fill="none""#))
        #expect(bold.contains(#"fill="currentColor""#))
        // Same geometry, different fill — so the toggle does not shift a pixel.
        let path = "M12 3.2l2.66 5.39"
        #expect(star.contains(path))
        #expect(bold.contains(path))
    }

    @Test("Asset names are unique — a collision would silently alias two glyphs")
    func assetNamesAreUnique() {
        let names = SupermuxZeronIcon.Name.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }

    @Test("No orphan imagesets: every catalog entry is reachable from the enum")
    func noOrphanImagesets() throws {
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropLast(".imageset".count)) }
        let cases = Set(SupermuxZeronIcon.Name.allCases.map(\.rawValue))
        for entry in entries {
            #expect(
                cases.contains(entry),
                "\(entry).imageset ships with no enum case — dead weight in the bundle"
            )
        }
    }
}

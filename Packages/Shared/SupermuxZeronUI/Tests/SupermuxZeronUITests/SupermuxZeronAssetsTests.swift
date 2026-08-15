//
//  SupermuxZeronAssetsTests.swift
//  SupermuxZeronUITests
//
//  Guards the vendored assets (plan §6.1/§6.2): the two Geist variable faces,
//  the OFL, the 18 Solar icon imagesets and their attribution.
//
//  These are FILE-LEVEL assertions on the resource bundle. Whether an icon
//  renders as a tintable template is a property of the compiled `Assets.car`,
//  which only `actool` produces — SwiftPM copies `.xcassets` verbatim and never
//  invokes it, so a `swift test` run has no catalog to load an image from. That
//  half is verified out-of-band with
//  `actool … --compile … && xcrun assetutil --info Assets.car` for `macosx`,
//  `iphoneos` and `iphonesimulator`; see the header of
//  `Icons/SupermuxZeronIconBundle.swift`.
//

import CoreText
import Foundation
import Testing

@testable import SupermuxZeronUI

@Suite("Zeron vendored assets")
struct SupermuxZeronAssetsTests {
    /// Every icon plan §6.2 names, with the render size(s) that consume it.
    private static let iconNames = [
        "alt-arrow-down", "arrow-up", "check", "checklist", "close-circle",
        "command", "copy", "danger-triangle", "document", "document-add",
        "folder", "folder-with-files", "git-branch", "global", "magnifer",
        "paperclip", "pen", "widget",
    ]

    private var resources: URL {
        get throws {
            try #require(Bundle.supermuxZeronUI.resourceURL)
        }
    }

    @Test("Both Geist variable faces are vendored, and only those two")
    func fontsAreVendored() throws {
        let fonts = try resources.appending(path: "Fonts")
        for face in ["Geist.ttf", "GeistMono.ttf"] {
            #expect(FileManager.default.fileExists(atPath: fonts.appending(path: face).path))
        }
        // The three static faces exist only for gpui's Linux cosmic-text path,
        // which ignores variable axes. CoreText applies `wght` natively.
        let ttfs = try FileManager.default
            .contentsOfDirectory(atPath: fonts.path)
            .filter { $0.hasSuffix(".ttf") }
            .sorted()
        #expect(ttfs == ["Geist.ttf", "GeistMono.ttf"])
    }

    @Test("The SIL Open Font License ships beside the fonts")
    func fontLicenseIsVendored() throws {
        let ofl = try String(
            contentsOf: resources.appending(path: "Fonts/OFL.txt"),
            encoding: .utf8
        )
        #expect(ofl.contains("SIL OPEN FONT LICENSE Version 1.1"))
        // The copyright line must be the one the VENDORED binaries declare in
        // their own `name` table (nameID 0), not the older
        // "Copyright (c) 2023 Vercel, in collaboration with basement.studio"
        // that upstream's `LICENSE.txt` still carries. OFL §2 conditions
        // redistribution on shipping the license the face was released under,
        // so a mismatched pair is a defective notice.
        #expect(ofl.contains("Copyright 2024 The Geist Project Authors"))
        #expect(!ofl.contains("basement.studio"), "the stale LICENSE.txt copyright must not ship")
        // The grant and the retention condition are the operative clauses; a
        // summarized license does not satisfy the OFL.
        #expect(ofl.contains("Permission is hereby granted, free of charge"))
        #expect(ofl.contains("PERMISSION & CONDITIONS"))
    }

    /// The OFL that ships must be the one the faces themselves point at — the
    /// check above is only meaningful if the binaries really do declare it.
    @Test("the vendored faces declare the copyright the shipped OFL carries")
    func fontLicenseMatchesTheBinaries() throws {
        let ofl = try String(
            contentsOf: resources.appending(path: "Fonts/OFL.txt"),
            encoding: .utf8
        )
        // Registration is LAZY and fires only on first access to
        // `SupermuxZeronFonts`. A bare `CTFontCreateWithName` before that
        // silently substitutes Helvetica — which is exactly the R10 failure
        // the whole diagnostic exists for, and it would make this assertion
        // read Apple's copyright instead of Geist's.
        try #require(SupermuxZeronFonts.isRegistered)

        for name in [
            SupermuxZeronFonts.sansRegularPostScriptName,
            SupermuxZeronFonts.monoRegularPostScriptName,
        ] {
            let font = CTFontCreateWithName(name as CFString, 14, nil)
            try #require(
                (CTFontCopyPostScriptName(font) as String) == name,
                "\(name) substituted — the copyright below would be the fallback's"
            )
            let copyright = try #require(
                CTFontCopyName(font, kCTFontCopyrightNameKey) as String?,
                "\(name) has no copyright metadata"
            )
            // The mono face appends ".git" to the same URL, so compare the
            // stable leading clause rather than the whole string.
            let declared = copyright.prefix(while: { $0 != "(" })
                .trimmingCharacters(in: .whitespaces)
            #expect(
                ofl.contains(declared),
                "\(name) declares \"\(copyright)\", which the shipped OFL does not carry"
            )
        }
    }

    @Test("Every plan §6.2 icon is present as a template-tinted vector imageset")
    func iconsAreVendored() throws {
        let catalog = try resources.appending(path: "Icons.xcassets")
        for name in Self.iconNames {
            let imageset = catalog.appending(path: "\(name).imageset")
            let svg = imageset.appending(path: "\(name).svg")
            #expect(
                FileManager.default.fileExists(atPath: svg.path),
                "missing icon asset \(name)"
            )

            let contents = try #require(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: imageset.appending(path: "Contents.json"))
                ) as? [String: Any]
            )
            let properties = try #require(contents["properties"] as? [String: Any])
            #expect(properties["preserves-vector-representation"] as? Bool == true)
            #expect(properties["template-rendering-intent"] as? String == "template")

            // `actool` reads the intrinsic point size from width/height, not
            // from viewBox: zeron's `1em` would compile to a 1x1 pt image.
            let markup = try String(contentsOf: svg, encoding: .utf8)
            #expect(!markup.contains("1em"), "\(name) still carries a 1em extent")
            #expect(markup.contains("currentColor"), "\(name) is not currentColor")
        }
    }

    @Test("The icon set carries its CC BY 4.0 attribution verbatim")
    func iconsCarryAttribution() throws {
        let attribution = try String(
            contentsOf: resources.appending(path: "Icons.xcassets/ATTRIBUTION.txt"),
            encoding: .utf8
        )
        #expect(attribution.contains("Solar Icons by 480 Design"))
        #expect(attribution.contains("https://creativecommons.org/licenses/by/4.0/"))
    }
}

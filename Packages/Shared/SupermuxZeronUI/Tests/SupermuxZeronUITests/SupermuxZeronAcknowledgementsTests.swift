//
//  SupermuxZeronAcknowledgementsTests.swift
//  SupermuxZeronUITests
//
//  The license notices the port is legally obliged to surface in-app.
//
//  These assertions exist because the failure mode is silent: a summarized MIT
//  body, a reworded CC BY attribution, or an OFL that drifts from the one
//  shipped next to the faces all render perfectly and all break the license.
//

import Foundation
import Testing

@testable import SupermuxZeronUI

@Suite("Zeron acknowledgements")
struct SupermuxZeronAcknowledgementsTests {
    @Test("The CC BY attribution string appears VERBATIM")
    func solarAttributionIsVerbatim() {
        // `icons.rs:7` names this exact string as *the* attribution. Rewording
        // it — even to something more polite — fails CC BY §3(a).
        let notice = SupermuxZeronNotice.solarIcons
        #expect(notice.title == "Solar Icons by 480 Design")
        #expect(notice.body.contains("Solar Icons by 480 Design"))
        #expect(notice.body.contains("https://creativecommons.org/licenses/by/4.0/"))
    }

    @Test("CC BY §3(a)'s 'indicate if changes were made' clause is satisfied")
    func solarNoticeDeclaresModifications() {
        let body = SupermuxZeronNotice.solarIcons.body
        // Changes WERE made: re-export to currentColor, mirrored glyphs, added
        // glyphs, and this port's own width/height rewrite.
        #expect(body.contains("Modified"))
        #expect(body.contains("currentColor"))
        #expect(body.contains("mirrored"))
        #expect(body.contains("viewBox"))
    }

    @Test("The MIT license is reproduced in FULL, not summarized")
    func mitIsReproducedInFull() {
        let body = SupermuxZeronNotice.zeronComet.body
        #expect(body.contains("Copyright (c) 2026 Wing"))
        // The three operative clauses. MIT's own condition is that the notice
        // travel with the software; a paraphrase does not satisfy it.
        #expect(body.contains("Permission is hereby granted, free of charge"))
        #expect(
            body.contains(
                "The above copyright notice and this permission notice shall be included"
            )
        )
        #expect(body.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }

    @Test("The OFL shown in-app IS the one shipped beside the faces")
    func oflMatchesTheShippedFile() throws {
        let resources = try #require(Bundle.supermuxZeronUI.resourceURL)
        let file = try String(
            contentsOf: resources.appending(path: "Fonts/OFL.txt"),
            encoding: .utf8
        )
        // Read at render time rather than retyped, so the two provably agree.
        #expect(SupermuxZeronNotice.geistFonts.body == file)
        #expect(file.contains("SIL OPEN FONT LICENSE Version 1.1"))
        #expect(file.contains("Copyright 2024 The Geist Project Authors"))
    }

    @Test("Every required notice is in the default set")
    func allNoticesArePresent() {
        let ids = SupermuxZeronNotice.all.map(\.id)
        // zeron/comet (MIT), Solar Icons (CC BY 4.0), Geist (OFL 1.1) — the
        // three bodies of third-party material this package redistributes.
        #expect(ids == ["zeron-comet", "solar-icons", "geist-fonts"])
    }

    @Test("Every notice names a license and a URL")
    func noticesAreWellFormed() {
        for notice in SupermuxZeronNotice.all {
            #expect(!notice.license.isEmpty, "\(notice.id) states no license")
            #expect(
                URL(string: notice.url) != nil,
                "\(notice.id) has no resolvable license URL"
            )
            #expect(!notice.summary.isEmpty, "\(notice.id) has no collapsed summary")
            #expect(!notice.body.isEmpty, "\(notice.id) has no full text")
        }
    }

    @Test("The repository NOTICE and the in-app view carry the same attributions")
    func repositoryNoticeAgreesWithTheView() throws {
        // The NOTICE file lives at the repo root, outside the bundle. Skip
        // rather than fail when the test runs from an installed artifact.
        let repoNotice = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SupermuxZeronUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SupermuxZeronUI
            .deletingLastPathComponent()  // Shared
            .deletingLastPathComponent()  // Packages
            .appending(path: "NOTICE")
        guard let text = try? String(contentsOf: repoNotice, encoding: .utf8) else { return }
        #expect(text.contains("Solar Icons by 480 Design"))
        #expect(text.contains("Copyright (c) 2026 Wing"))
        #expect(text.contains("Copyright 2024 The Geist Project Authors"))
    }
}

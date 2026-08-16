//
//  SupermuxZeronAcknowledgements.swift
//  SupermuxZeronUI
//
//  The in-app credits surface. Plan §6.2–§6.4, spec 08 §6.5.
//
//  ── Why this is a VIEW and not just the repo NOTICE file ──
//
//  CC BY 4.0 §3(a) requires attribution "reasonable to the medium". For a
//  shipped application that means a credits screen the user can actually reach
//  — a file in the source tree does not satisfy it for a binary distribution.
//  The MIT license carries its own condition ("shall be included in all copies
//  or substantial portions"), and the OFL requires its text to travel with the
//  faces. So all three notices are reproduced here, in full, and rendered.
//
//  ── What must be verbatim ──
//
//  * `Solar Icons by 480 Design` — `icons.rs:7` names it as *the* attribution
//    string. Do not reword it, do not translate it, do not abbreviate it.
//  * The MIT body — reproduced in full, never summarized.
//  * The OFL — read out of the shipped `Fonts/OFL.txt` at render time rather
//    than retyped, so the text on screen is provably the text next to the
//    binaries. `SupermuxZeronAcknowledgementsTests` asserts the two agree.
//
//  ── Brand marks ──
//
//  This port ships **none** (plan §6.4 default). No license is asserted for
//  zeron's brand marks anywhere in its repo, and trademark is not granted by
//  MIT or CC BY. If a mark is ever added, §6.5D's disclaimer must be added
//  here with it — hence ``trademarkDisclaimer``, present and unused, so the
//  next person finds it rather than inventing one.
//

public import SwiftUI

internal import Foundation

// MARK: - Notices

/// One third-party notice: what it covers, and the text the license obliges us
/// to reproduce.
public struct SupermuxZeronNotice: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    /// The component, as the user should see it named.
    public let title: String
    /// The license, spelled out.
    public let license: String
    /// The canonical URL for the license or the upstream project.
    public let url: String
    /// The one-line summary shown collapsed.
    public let summary: String
    /// The full text the license requires. Never summarized.
    public let body: String

    public init(
        id: String,
        title: String,
        license: String,
        url: String,
        summary: String,
        body: String
    ) {
        self.id = id
        self.title = title
        self.license = license
        self.url = url
        self.summary = summary
        self.body = body
    }
}

public extension SupermuxZeronNotice {
    /// zeron/comet — MIT. The body is the upstream `LICENSE` verbatim.
    static let zeronComet = SupermuxZeronNotice(
        id: "zeron-comet",
        title: "zeron/comet",
        license: "MIT License",
        url: "https://opensource.org/licenses/MIT",
        summary: "Portions of this software are derived from zeron/comet.",
        body: """
        Portions of this software are derived from zeron/comet.

        zeron/comet
        Copyright (c) 2026 Wing
        Licensed under the MIT License.

        MIT License

        Copyright (c) 2026 Wing

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """
    )

    /// Solar Icons — CC BY 4.0. The attribution line is verbatim from
    /// `icons.rs:7`, and CC BY §3(a) also obliges the "indicate if changes were
    /// made" clause, which is why the modifications are itemized.
    static let solarIcons = SupermuxZeronNotice(
        id: "solar-icons",
        title: "Solar Icons by 480 Design",
        license: "Creative Commons Attribution 4.0 International (CC BY 4.0)",
        url: "https://creativecommons.org/licenses/by/4.0/",
        summary: "Solar Icons by 480 Design — CC BY 4.0.",
        body: """
        Icons: Solar Icons by 480 Design — https://creativecommons.org/licenses/by/4.0/
        Licensed under CC BY 4.0. Modified: re-exported to currentColor, several
        glyphs mirrored, and additional glyphs drawn in the same style.

        The glyphs came through zeron/comet (MIT), which re-exported the Solar
        Linear set to currentColor and drew a handful of additional glyphs in the
        same style at heavier stroke weights.

        Further modification made here: each vendored SVG's width/height attributes
        were rewritten from the "1em" extent zeron ships to the glyph's own viewBox
        extent, so the asset compiler derives the correct intrinsic point size. No
        path data, stroke weight, or color was changed.
        """
    )

    /// Geist / Geist Mono — SIL OFL 1.1. The body is loaded from the shipped
    /// `OFL.txt` so the credits screen and the file next to the binaries can
    /// never disagree.
    static let geistFonts = SupermuxZeronNotice(
        id: "geist-fonts",
        title: "Geist and Geist Mono",
        license: "SIL Open Font License, Version 1.1",
        url: "https://github.com/vercel/geist-font",
        summary: "Geist and Geist Mono, Copyright 2024 The Geist Project Authors.",
        body: Self.bundledOFL
    )

    /// Every notice this package's material requires, in the order the plan
    /// lists them.
    static let all: [SupermuxZeronNotice] = [zeronComet, solarIcons, geistFonts]

    /// The §6.5D disclaimer. **Unused** — this port ships no brand marks. It
    /// exists so that adding one surfaces the obligation instead of shipping
    /// silently.
    static let trademarkDisclaimer = """
        Product names and logos are trademarks of their respective holders and are
        used only to identify the corresponding services. No affiliation or
        endorsement is implied.
        """

    /// The vendored `OFL.txt`, verbatim.
    ///
    /// A missing file is a shipping defect, not a runtime condition to route
    /// around: the fallback names the exact path so the failure is diagnosable
    /// from a screenshot, and the asset test fails long before that.
    private static var bundledOFL: String {
        guard let url = Bundle.supermuxZeronUI.url(
            forResource: "OFL",
            withExtension: "txt",
            subdirectory: "Fonts"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return """
            Geist and Geist Mono
            Copyright 2024 The Geist Project Authors (https://github.com/vercel/geist-font)
            Licensed under the SIL Open Font License, Version 1.1.

            The full license text ships at Resources/Fonts/OFL.txt and could not be
            read from this bundle.
            """
        }
        return text
    }
}

// MARK: - View

/// The Acknowledgements list, in zeron chrome.
///
/// Presented from the app's About/Settings surface. Every notice starts
/// collapsed to its summary and expands to the full obligated text; the
/// **attribution lines are always visible** whether or not a row is expanded,
/// because they are what the licenses actually require to be seen.
public struct SupermuxZeronAcknowledgementsView: View {
    private let theme: SupermuxZeronTheme
    private let notices: [SupermuxZeronNotice]

    @State private var expanded: Set<String> = []

    public init(
        theme: SupermuxZeronTheme,
        notices: [SupermuxZeronNotice] = SupermuxZeronNotice.all
    ) {
        self.theme = theme
        self.notices = notices
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SupermuxZeronMetrics.Theme.spaceLG) {
                Text(Self.heading)
                    .font(SupermuxZeronFonts.sans(size: 16, weight: .medium))
                    .foregroundStyle(theme.text)

                Text(Self.preamble)
                    .font(SupermuxZeronFonts.sans(size: 13))
                    .foregroundStyle(theme.textMuted.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(notices) { notice in
                    card(notice)
                }
            }
            .padding(SupermuxZeronMetrics.Theme.spaceLG)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.bg)
    }

    private func card(_ notice: SupermuxZeronNotice) -> some View {
        let isExpanded = expanded.contains(notice.id)
        return VStack(alignment: .leading, spacing: SupermuxZeronMetrics.Theme.spaceSM) {
            Text(notice.title)
                .font(SupermuxZeronFonts.sans(size: 13, weight: .medium))
                .foregroundStyle(theme.text)

            Text(notice.license)
                .font(SupermuxZeronFonts.sans(size: 11))
                .foregroundStyle(theme.textMuted.opacity(0.7))

            // The attribution line stays visible collapsed — it is the part the
            // license obliges the user to see.
            Text(notice.summary)
                .font(SupermuxZeronFonts.sans(size: 12))
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let url = URL(string: notice.url) {
                Link(notice.url, destination: url)
                    .font(SupermuxZeronFonts.sans(size: 11))
                    .foregroundStyle(theme.accent)
            }

            if isExpanded {
                Text(notice.body)
                    .font(SupermuxZeronFonts.mono(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SupermuxZeronMetrics.Theme.spaceXS)
            }

            Button {
                if isExpanded {
                    expanded.remove(notice.id)
                } else {
                    expanded.insert(notice.id)
                }
            } label: {
                Text(isExpanded ? Self.hideLicense : Self.showLicense)
                    .font(SupermuxZeronFonts.sans(size: 11, weight: .medium))
                    .foregroundStyle(theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(SupermuxZeronMetrics.Theme.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: SupermuxZeronMetrics.Theme.panelRadius, style: .continuous
            )
            .fill(theme.ink(0.03))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: SupermuxZeronMetrics.Theme.panelRadius, style: .continuous
            )
            .strokeBorder(theme.hairline(0.07), lineWidth: 1)
        )
    }

    // MARK: Strings

    private static var heading: String {
        String(
            localized: "supermux.zeron.acknowledgements.title",
            defaultValue: "Acknowledgements",
            bundle: .supermuxZeronUI
        )
    }

    private static var preamble: String {
        String(
            localized: "supermux.zeron.acknowledgements.preamble",
            defaultValue: """
                The Claude Code chat pane is a SwiftUI port of zeron/comet's chat pane. \
                It redistributes the third-party material below under the licenses shown.
                """,
            bundle: .supermuxZeronUI
        )
    }

    private static var showLicense: String {
        String(
            localized: "supermux.zeron.acknowledgements.show",
            defaultValue: "Show full license",
            bundle: .supermuxZeronUI
        )
    }

    private static var hideLicense: String {
        String(
            localized: "supermux.zeron.acknowledgements.hide",
            defaultValue: "Hide full license",
            bundle: .supermuxZeronUI
        )
    }
}

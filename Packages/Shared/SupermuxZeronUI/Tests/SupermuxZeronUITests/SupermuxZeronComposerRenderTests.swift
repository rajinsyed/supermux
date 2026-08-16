//
//  SupermuxZeronComposerRenderTests.swift
//  SupermuxZeronUITests
//
//  Border-box parity for the composer's four laid-out boxes.
//
//  ── Why these are render tests and not formula tests ──
//
//  Every one of these regressions was a SwiftUI/gpui box-model mismatch, not a
//  wrong constant: `SupermuxZeronMetrics` already held 46, 76, 49 and 768, and
//  the flip reducer already returned them. gpui's `.h()` / `.max_w()` size the
//  BORDER box, so `pt-1 pb-2.5` sits inside the 46 and the composer's `px-16`
//  sits inside the 768; SwiftUI's `.frame()` sizes the CONTENT box, so the same
//  modifier order adds the padding on the outside instead. A test that
//  re-derives `4 + 32 + 10 == 46` from the constants cannot see that — it has to
//  lay the view out and read the frame back.
//
//  Measured failures these pin (all confirmed against a real `NSHostingView`
//  before the fix): actions row 60 vs 46, expanded text box 96 vs 76, composer
//  column 768 vs 736, and a trigger chip inflating to its 208 pt cap.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import SupermuxZeronUI

#if canImport(AppKit)
import AppKit
#endif

/// A one-slot sink for a `GeometryReader` read, so the measuring helper can be
/// generic (a nested type cannot be).
@MainActor
private final class MeasuredWidth {
    var value: CGFloat?
}

@MainActor
struct SupermuxZeronComposerRenderTests {
    private typealias Metrics = SupermuxZeronMetrics.Composer
    private typealias Flip = SupermuxZeronComposerFlip

    private let theme = SupermuxZeronTheme(isDark: true)
    /// `max_w(768)` minus the container's own `px(16)` — the pill's real width,
    /// and what `docs/screenshot.png` samples (x 495 → 1231 ≈ 737 with AA).
    private let pillWidth: CGFloat = 736

    /// The width `view` actually claims when a parent OFFERS it `offering`.
    ///
    /// The view is placed in a fixed-width container and read back through a
    /// `GeometryReader` on its own background — measuring the host's
    /// `fittingSize` instead would just return the width we forced on it, which
    /// is exactly the question being asked.
    private func width(of view: some View, offering: CGFloat) -> CGFloat? {
        #if canImport(AppKit)
        let box = MeasuredWidth()
        let probe = HStack(spacing: 0) {
            view.background(
                GeometryReader { proxy in
                    Color.clear.onAppear { box.value = proxy.size.width }
                }
            )
            // Soaks up whatever the subject does not claim, so a subject that
            // hugs reports its own width rather than the container's.
            Spacer(minLength: 0)
        }
        .frame(width: offering)

        let host = NSHostingView(rootView: AnyView(probe))
        host.frame = NSRect(x: 0, y: 0, width: offering, height: 200)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return box.value
        #else
        return nil
        #endif
    }

    // MARK: - The pill's own box

    @Test("the compact pill lays out at exactly COMPACT_TOTAL_HEIGHT (49)")
    func compactPillIsFortyNine() {
        let pill = SupermuxZeronComposerPill(
            theme: theme,
            expanded: false,
            height: Metrics.compactTotal,
            baseHeight: Metrics.compactTotal
        ) {
            Text("Do anything…")
        } actions: {
            SupermuxZeronActionsRow(
                theme: theme,
                model: .init(modelLabel: "Sonnet 4.6", effortLabel: "High"),
                sendMode: .send
            )
        }
        let measured = SupermuxZeronRenderProbe.height(of: pill, width: pillWidth)
        #expect(measured.matchesAnalytic(Metrics.compactTotal))
    }

    @Test("the EMPTY expanded pill lays out at COMPOSER_MIN_HEIGHT (124), not 144")
    func expandedPillIsOneTwentyFour() {
        // The regression: the text box's 76 is the textarea's BORDER box
        // ("content + `pt-4 pb-1`", which is why 76 + 46 + 2 = 124). Sizing the
        // content box to 76 and THEN padding made it 96, and the pill overflowed
        // its own committed height by exactly TEXTAREA_PAD_V.
        let base = Flip.baseHeight(expanded: true, contentHeight: Metrics.inputLineHeight)
        #expect(base == Metrics.minHeight)

        let pill = SupermuxZeronComposerPill(
            theme: theme,
            expanded: true,
            height: base,
            baseHeight: base
        ) {
            Text("Do anything…")
        } actions: {
            SupermuxZeronActionsRow(
                theme: theme,
                model: .init(modelLabel: "Sonnet 4.6", effortLabel: "High"),
                sendMode: .send
            )
        }
        let measured = SupermuxZeronRenderProbe.height(of: pill, width: pillWidth)
        #expect(measured.matchesAnalytic(Metrics.minHeight))
    }

    @Test("a grown expanded pill still lays out at its committed height")
    func expandedPillTracksAutoGrow() {
        // 4 lines → 159 is the spec's own `auto_grow_math` fixture.
        let base = Flip.baseHeight(
            expanded: true,
            contentHeight: Flip.contentHeight(wrappedLineCount: 4)
        )
        #expect(base == 159)

        let pill = SupermuxZeronComposerPill(
            theme: theme,
            expanded: true,
            height: base,
            baseHeight: base
        ) {
            Text("one\ntwo\nthree\nfour")
        } actions: {
            SupermuxZeronActionsRow(
                theme: theme,
                model: .init(modelLabel: "Sonnet 4.6"),
                sendMode: .send
            )
        }
        #expect(SupermuxZeronRenderProbe.height(of: pill, width: pillWidth).matchesAnalytic(159))
    }

    // MARK: - The 46 pt actions row

    @Test("the actions row's 46 pt is the BORDER box — pt-1 and pb-2.5 sit inside it")
    func actionsRowIsFortySix() {
        // 4 + 32 + 10 = 46. Applying `.frame(height: 46)` before the padding
        // measured 60 and lifted the whole cluster 7 pt off the pill's bottom.
        let row = HStack(spacing: Flip.clusterGap) {
            SupermuxZeronActionsRow(
                theme: theme,
                model: .init(modelLabel: "Sonnet 4.6", effortLabel: "High"),
                sendMode: .send
            )
        }
        .padding(.leading, Flip.actionsPadLeading)
        .padding(.trailing, Flip.clusterInset(expanded: true, morph: 1))
        .padding(.top, Flip.actionsPadTop)
        .padding(.bottom, Flip.actionsPadBottom)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: Metrics.actionsRowHeight)

        #expect(
            SupermuxZeronRenderProbe.height(of: row, width: pillWidth)
                .matchesAnalytic(Metrics.actionsRowHeight)
        )
    }

    // MARK: - The trigger chip

    @Test("a trigger chip HUGS its label instead of inflating to the 208 pt cap")
    func triggerChipHugs() {
        let chip = SupermuxZeronTriggerChip(
            theme: theme,
            label: "High",
            isSet: false,
            action: {}
        )
        // gpui `max_w(208)` is a cap over a content-sized box. Offered 736 pt,
        // the chip must still measure its own text plus 2 × 10 pt of padding —
        // far under the cap, and nowhere near the offered width.
        guard let measured = width(of: chip, offering: pillWidth) else { return }
        #expect(measured < Flip.chipMaxWidth)
        #expect(measured < 120, "\"High\" at 12 pt Medium + px-10 is a narrow chip")
    }

    @Test("a trigger chip truncates AT the 208 pt cap rather than growing past it")
    func triggerChipCaps() {
        let chip = SupermuxZeronTriggerChip(
            theme: theme,
            label: String(repeating: "a very long model name ", count: 8),
            isSet: true,
            action: {}
        )
        guard let measured = width(of: chip, offering: 2_000) else { return }
        #expect(measured <= Flip.chipMaxWidth + SupermuxZeronRenderProbe.tolerance)
    }

    @Test("the chip is 32 pt tall — h-8, the tallest child the 46 pt row is built around")
    func triggerChipHeight() {
        let chip = SupermuxZeronTriggerChip(theme: theme, label: "High", isSet: false, action: {})
        #expect(
            SupermuxZeronRenderProbe.height(of: chip, width: pillWidth)
                .matchesAnalytic(Metrics.triggerChipHeight)
        )
    }

    // MARK: - The reserved status strip

    @Test("the status strip reserves its 24 pt box in EVERY state, including empty")
    func statusStripAlwaysReservesHeight() {
        // Reserving it unconditionally is what stops the composer shifting when
        // a run starts or ends, and `bottom_band = stack_h − 24` depends on it.
        for state in [
            SupermuxZeronStatusStripState.idle,
            .working,
            .awaitingInput,
            .errored,
            .sending,
        ] {
            let strip = SupermuxZeronStatusStrip(theme: theme, state: state)
            #expect(
                SupermuxZeronRenderProbe.height(of: strip, width: 1_200)
                    .matchesAnalytic(SupermuxZeronMetrics.Theme.statusStripHeight),
                "\(state) must still reserve 24 pt"
            )
        }
    }

    // MARK: - Strings

    /// The package's string catalog, read as JSON.
    ///
    /// SwiftPM copies `.xcstrings` UNCOMPILED (only Xcode runs
    /// `xcstringstool` over it), exactly like `Icons.xcassets` — so runtime
    /// `String(localized:)` cannot be asserted under `swift test`, and the
    /// catalog is checked as source instead. Same rationale as the icon probe.
    private func catalogEntry(_ key: String) -> [String: Any]? {
        guard let url = Bundle.supermuxZeronUI.url(
            forResource: "Localizable",
            withExtension: "xcstrings"
        ),
        let data = try? Data(contentsOf: url),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let strings = root["strings"] as? [String: Any]
        else { return nil }
        return strings[key] as? [String: Any]
    }

    /// The value a key carries in one language, or nil when it is absent.
    private func catalogValue(_ key: String, language: String) -> String? {
        guard let entry = catalogEntry(key),
              let locs = entry["localizations"] as? [String: Any],
              let lang = locs[language] as? [String: Any],
              let unit = lang["stringUnit"] as? [String: Any]
        else { return nil }
        return unit["value"] as? String
    }

    @Test("the placeholder is zeron's exact string, with a real U+2026 ellipsis")
    func placeholderIsExact() {
        // `composer.rs:3369` is "Do anything…" with one ELLIPSIS code point.
        // Three periods is a different string and shapes differently at 14 pt.
        //
        // It lives in the SHARED catalog deliberately: the app target still
        // carries a *translated* `supermux.harness.composer.placeholder`
        // ("Message Claude Code" / 「Claude Code にメッセージ」), so the pre-port key
        // would have returned that in both languages and never reached the
        // zeron default at all.
        guard let english = catalogValue(
            "supermux.zeron.composer.placeholder", language: "en"
        ) else {
            Issue.record("the placeholder is missing from the package catalog")
            return
        }
        #expect(english == "Do anything…")
        #expect(english.contains("\u{2026}"))
        #expect(!english.contains("..."))
    }

    @Test("every composer string is in the package catalog, in BOTH languages")
    func composerStringsAreInTheCatalog() {
        // A key missing from the catalog silently returns its `defaultValue` in
        // every language — the same silent-fallback failure mode W0 guards
        // against for fonts.
        for key in [
            "supermux.zeron.composer.placeholder",
            "supermux.zeron.composer.traits",
            "supermux.zeron.composer.fast",
            "supermux.zeron.composer.thinking",
            "supermux.zeron.composer.send",
            "supermux.zeron.composer.steer",
            "supermux.zeron.composer.steerHint",
            "supermux.zeron.composer.stop",
            "supermux.zeron.composer.attach",
            "supermux.zeron.status.sending",
            "supermux.zeron.status.runFailed",
            "supermux.zeron.slash.noCommands",
            "supermux.zeron.slash.noMatches",
            "supermux.zeron.attachment.remove",
            "supermux.zeron.attachment.unsupported",
            "supermux.zeron.attachment.unreadable",
            "supermux.zeron.attachment.tooLarge",
        ] {
            for language in ["en", "ja"] {
                let value = catalogValue(key, language: language)
                #expect(
                    value?.isEmpty == false,
                    "\(key) has no \(language) translation in the package catalog"
                )
            }
        }
    }

    @Test("the strip spans the pane and centres its own 768 column, like the composer's")
    func statusStripSpansThePane() {
        // `w_full().max_w(768).mx_auto().px(24)`. The OUTER box is full-width
        // (`w_full`) — that is what centres the inner 768 — while the caption
        // lands 24 pt inside that centred column, i.e. 8 pt further in than the
        // pill's own 16. Both insets live INSIDE the 768 because gpui's `max_w`
        // caps the border box.
        //
        // The pairing is the real contract, so it is asserted as arithmetic over
        // the two constants the two views actually use, and the render check
        // below pins that the strip still claims the whole pane (a strip that
        // shrink-wrapped would stop centring and drift with its own caption).
        #expect(
            (SupermuxZeronMetrics.Theme.spaceLG + 8) - Metrics.containerPadX == 8,
            "the strip's px-24 is exactly 8 pt deeper than the column's px-16"
        )

        let pane: CGFloat = 1_600
        guard let measured = width(
            of: SupermuxZeronStatusStrip(theme: theme, state: .errored),
            offering: pane
        ) else { return }
        #expect(abs(measured - pane) <= SupermuxZeronRenderProbe.tolerance)
    }
}

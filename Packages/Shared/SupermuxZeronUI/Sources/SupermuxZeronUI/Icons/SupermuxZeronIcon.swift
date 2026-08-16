//
//  SupermuxZeronIcon.swift
//  SupermuxZeronUI
//
//  The vendored zeron/comet glyph set as one tintable SwiftUI view.
//  Plan §6.2, spec 08 §4.
//
//  ── Why a vector asset and not an SF Symbol ──
//
//  Solar Icons (Linear weight) normalizes to a **0.0625 em** stroke — 1.5 on a
//  24 grid — which is *lighter* than SF Symbols' `.regular`, and its corner
//  treatment is a distinctive superellipse. Two of the glyphs here have no
//  acceptable SF equivalent at all: `document-add` is a pen over a page (not a
//  plus badge) and `folder-with-files` has no counterpart. Substituting SF
//  Symbols anywhere in this set breaks the visual weight of every chip row it
//  appears in, so the whole set ships as vectors (08 §4.2).
//
//  Three stroke families coexist deliberately and must not be normalized:
//  Solar 24-grid at 1.5 (0.0625 em), zeron's hand-drawn 16-grid at 1.25
//  (0.0781 em, 25 % heavier), and `check` alone at 1.6 (0.1000 em, 60 %
//  heavier). Do not "fix" the outliers.
//
//  ── Tinting ──
//
//  Every imageset carries `template-rendering-intent: "template"` **and** this
//  view re-asserts `.renderingMode(.template)`, so `.foregroundStyle` colors
//  the glyph exactly as gpui's `text_color` does. Every SVG paints with
//  `currentColor`, which is what makes that work.
//
//  ── Sizing ──
//
//  gpui ignores an SVG's own extent and applies the caller's `.size(px(N))`.
//  This view does the same: the frame is always explicit, taken from the
//  render-size table in the doc comment on each case. Never rely on the
//  asset's intrinsic size — it is only the viewBox extent.
//
//  ── Catalog compilation ──
//
//  `swift build`/`swift test` copy `.xcassets` verbatim and NEVER invoke
//  `actool`, so there is no `Assets.car` to load an image from in a SwiftPM
//  test process. Asset PRESENCE is asserted at file level in
//  `SupermuxZeronIconTests`; the template/vector renditions are verified in the
//  `xcodebuild` leg, which does run `actool`.
//

public import SwiftUI

/// A vendored zeron glyph, template-tinted and sized in points.
///
/// ```swift
/// SupermuxZeronIcon(.magnifer, size: 14)
///     .foregroundStyle(theme.textMuted.opacity(0.7))
/// ```
///
/// The view paints nothing but the glyph — no padding, no plate, no baseline
/// alignment. Callers own their tile.
public struct SupermuxZeronIcon: View {
    /// The vendored set. The raw value is the asset name in `Icons.xcassets`,
    /// which is also the source SVG's filename in
    /// `zeron-comet/crates/ui/assets/icons/`.
    ///
    /// lint:allow namespace-type — the asset table of a real `View` value.
    /// (lint:allow)
    public enum Name: String, Sendable, Equatable, Hashable, CaseIterable {
        // MARK: Tool chips (spec 03) — rendered at 12

        /// Exec chip; also the slash-menu ⌘ badge at 14. Solar Linear.
        case command
        /// Read + ApplyPatch chips; file mentions at 14. Solar Linear.
        case document
        /// Write chip. Solar Linear — a **pen over a page**, not a plus badge.
        case documentAdd = "document-add"
        /// Edit chip. Solar Linear.
        case pen
        /// Search chip at 12; the picker's search row at 14. Solar Linear.
        case magnifer
        /// Glob chip; the composer's worktree footer chip. Solar Linear.
        case folderWithFiles = "folder-with-files"
        /// WebFetch + WebSearch chips. Solar Linear.
        case global
        /// Todo chip. Solar Linear.
        case checklist
        /// MCP + Unknown chips. Solar Linear.
        case widget

        // MARK: Markdown code blocks (spec 05) — rendered at 12

        /// Code-block copy button. Solar Linear.
        case copy
        /// Copy confirmation. zeron hand-drawn on a **16 grid at 1.6** — the
        /// heaviest glyph in the set, deliberately.
        case check

        // MARK: Composer (spec 04)

        /// Send / steer button, 14. Solar Linear.
        case arrowUp = "arrow-up"
        /// Attach button, 16. Solar Linear.
        case paperclip
        /// Attachment + error dismiss, 14. Solar Linear.
        case closeCircle = "close-circle"
        /// Composer error chip at 14; transcript error chip at 12. Solar Linear.
        case dangerTriangle = "danger-triangle"
        /// Composer footer cwd chip, 12. Solar Linear.
        case folder
        /// Composer footer branch chip, 12. zeron hand-drawn in the Solar
        /// Linear style — "the set has no branch icon".
        case gitBranch = "git-branch"
        /// Footer chip caret, 12. Solar Linear.
        case altArrowDown = "alt-arrow-down"

        // MARK: Transcript + pickers (spec 02, 08)

        /// Jump-to-bottom pill; the footer hint pair at 12.5. Solar Linear,
        /// **`arrow-up` mirrored** — the set has no plain arrow-down.
        case arrowDown = "arrow-down"
        /// Enter key cap in a footer hint bar, 12.5. zeron hand-drawn — the
        /// set has no return glyph.
        case `return`
        /// Picker row favorite, off state, 13. zeron hand-drawn in the Solar
        /// Linear style.
        case star
        /// Picker row favorite, on state, 13; the favorites rail tab at 17.
        /// The same path as ``star``, filled with `currentColor`.
        case starBold = "star-bold"
        /// The picker rail's "all models" tab, 18. Solar Linear.
        ///
        /// zeron's rail has one brand mark per harness; supermux has exactly
        /// one harness (plan §0.4), so this neutral list glyph stands in for
        /// the brand tab rather than shipping a third-party trademark
        /// (plan §6.4 — default: ship none).
        case list

        /// The asset name inside `Icons.xcassets`.
        public var assetName: String { rawValue }
    }

    /// Which glyph to paint.
    public let name: Name
    /// The painted extent, in points. Both axes — every glyph is square.
    public let size: CGFloat

    /// Creates a template-tinted glyph at an explicit point size.
    /// - Parameters:
    ///   - name: The vendored glyph.
    ///   - size: The painted extent in points; take it from the render-size
    ///     table on the case, never from the asset's intrinsic size.
    public init(_ name: Name, size: CGFloat) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        Image(name.rawValue, bundle: .supermuxZeronUI)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            // The glyph is decoration in every seat it currently occupies —
            // the chip verb, the row label, or the button's own label carries
            // the accessible name. A per-glyph label would double-read.
            .accessibilityHidden(true)
    }
}

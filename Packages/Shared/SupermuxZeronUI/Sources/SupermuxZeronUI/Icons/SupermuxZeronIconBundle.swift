//
//  SupermuxZeronIconBundle.swift
//  SupermuxZeronUI
//
//  Resource-bundle access for the vendored zeron icon set.
//
//  ── Why the icons ship as .imageset entries holding the raw SVG, not PDFs ──
//
//  Plan §6.2 suggests PDF vector assets. We ship SVG imagesets with
//  `preserves-vector-representation: true` + `template-rendering-intent:
//  "template"` instead, because:
//
//  1. It is lossless. Converting to PDF needs a rasterizer/renderer that is not
//     present on this toolchain (no rsvg-convert, cairosvg, or Inkscape; the
//     bundled ImageMagick delegates SVG to the missing rsvg-convert), so every
//     conversion path available would have gone through a re-draw we cannot
//     byte-verify against the source. The SVGs are the ground truth zeron ships.
//  2. `actool` accepts SVG natively for macOS 12+/iOS 13+ and emits a real
//     `Vector` rendition plus template-tagged @1x/@2x/@3x images. Verified with
//     `xcrun assetutil --info` on the compiled `Assets.car` for `macosx`,
//     `iphoneos` and `iphonesimulator`: 18 vectors, every image `Template Mode:
//     template` and `Preserved Vector Representation: true`, so
//     `.foregroundStyle` tints them exactly as gpui's `text_color` does.
//  3. Both platforms get the SAME file; a PDF path would have needed separate
//     verification anyway.
//
//  ── The one modification made to the vendored SVGs ──
//
//  zeron ships `width="1em" height="1em"` (a gpui/web idiom). `actool` derives
//  an asset's intrinsic POINT size from `width`/`height`, not from `viewBox`, so
//  the unmodified files compile to a 1x1 pt image — every icon would render as a
//  single point. Each file's `width`/`height` is therefore rewritten to its own
//  `viewBox` extent (24x24, or 16x16 for `check` and `git-branch`). Path data,
//  stroke weights, `currentColor` and `fill="none"` are untouched.
//
//  Call sites should size explicitly (`.frame(width: 12, height: 12)`) per the
//  §6.2 render-size table rather than relying on the intrinsic size.
//

public import Foundation

public extension Bundle {
    /// The `SupermuxZeronUI` resource bundle: `Fonts/` and `Icons.xcassets`.
    ///
    /// SPM's generated `Bundle.module` is internal to the target, so platform
    /// shells and tests reach the vendored fonts and icons through this.
    static var supermuxZeronUI: Bundle { .module }
}

//
//  SupermuxZeronTokens.swift
//  SupermuxZeronUI
//
//  The zeron/comet color system, ported 1:1. Plan §1.1, §1.2, §1.3.
//
//  Nothing else in the codebase may declare a color literal. Every value here
//  comes from `/tmp/zeron-comet/crates/ui/src/theme.rs` by way of the extraction
//  specs; the plan's §0.3 conflict rulings (C1–C5, C7, C13) are applied inline
//  and flagged at their call sites.
//
//  ── Two rules that must never be broken (plan §1.1) ──
//
//  1. Hover/wash fades rest at `ink(0)` / `wash(0)` — white-at-zero-alpha,
//     NEVER `Color.clear` — or the mid-fade flashes grey. SwiftUI blends
//     premultiplied, so animating the *opacity* of a fixed `ink(a)` overlay is
//     the faithful equivalent of zeron's `motion::mix`.
//  2. Never bake a composited opaque hex for a translucent token. The macOS
//     shell is real glass and the ground varies with the wallpaper. The
//     composited hexes quoted in comments are VERIFICATION FIXTURES only.
//

public import SwiftUI

// MARK: - Hex helper

public extension Color {
    /// An sRGB color from a packed `0xRRGGBB` literal.
    ///
    /// All zeron colors are **sRGB**, not display-P3 — gpui composites in sRGB.
    /// `Color(hue:saturation:brightness:)` is HSB, not HSL; never route zeron's
    /// `Hsla` values through it.
    static func zeron(_ hex: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255,
              opacity: a)
    }
}

// MARK: - Ink helpers

/// The translucent-ink helpers (`theme.rs:807/826/839/860/875`).
///
/// **Every alpha in this design system is authored in DARK-MODE terms**; the
/// light value is derived by these two rules and nothing else:
/// fills ×`fillScale` (1.0), hairlines ×`hairlineScale` (1.35) capped at 0.5.
/// Keep one number per call site and let these functions do the flip.
///
/// lint:allow namespace-type — pure helper table (data + math, not behavior).
/// (lint:allow)
public enum ZeronInk {
    /// `INK_FILL_SCALE` (`theme.rs:138`). Exactly 1.0, deliberately: halving
    /// light alphas once erased the composer plate (`ink(0.03)`) entirely.
    /// Only the *tone* flips between appearances, never the strength.
    public static let fillScale = 1.00
    /// `INK_HAIRLINE_SCALE` (`theme.rs:144`), capped at α 0.5 — a 1 pt edge
    /// needs MORE ink to survive a bright surround.
    public static let hairlineScale = 1.35
    /// The hard cap applied after `hairlineScale`.
    public static let hairlineAlphaCap = 0.5

    /// Translucent FILL ink — plates, tiles, chip cards, the guide rail.
    public static func ink(_ a: Double, dark: Bool) -> Color {
        dark ? .zeron(0xFFFFFF, a) : .zeron(0x000000, a * fillScale)
    }

    /// Translucent EDGE ink — borders and dividers.
    public static func hairline(_ a: Double, dark: Bool) -> Color {
        dark ? .zeron(0xFFFFFF, a) : .zeron(0x000000, min(a * hairlineScale, hairlineAlphaCap))
    }

    /// Softened state wash. The 0.92 / 0.10 lightness stops short of pure so a
    /// hover plate reads as tinted glass rather than paint.
    public static func wash(_ a: Double, dark: Bool) -> Color {
        dark ? .zeron(0xEBEBEB, a) : .zeron(0x1A1A1A, a * fillScale)
    }

    /// Modal backdrop. Black in BOTH appearances — a white "light scrim" would
    /// wash the modal out. Light runs at ~53 % of dark's strength.
    public static func scrim(_ aDark: Double, dark: Bool) -> Color {
        dark ? .zeron(0x000000, aDark) : .zeron(0x000000, 0.32 * (aDark / 0.60))
    }

    /// The recessed strip behind a picker header/footer. Translucent black in
    /// both modes so the glass reads through; light is far weaker because the
    /// dark 16 % "would read as a bruise" on white.
    public static func band(dark: Bool) -> Color {
        dark ? .zeron(0x000000, 0.16) : .zeron(0x000000, 0.045)
    }
}

// MARK: - Theme

/// The zeron palette, keyed by appearance.
///
/// Construct one per `body` — it stores a single `Bool` and every token is a
/// computed `Color`, so there is no global mutable state and no cache to
/// invalidate. `Sendable` by construction.
///
/// ```swift
/// let theme = SupermuxZeronTheme(isDark: colorScheme == .dark)
/// Text(row.text).foregroundStyle(theme.text)
/// ```
public struct SupermuxZeronTheme: Sendable, Equatable, Hashable {
    public let isDark: Bool

    public init(isDark: Bool) { self.isDark = isDark }

    /// `SupermuxZeronTheme(isDark: colorScheme == .dark)`.
    public init(_ colorScheme: ColorScheme) { self.isDark = colorScheme == .dark }

    public static let dark = SupermuxZeronTheme(isDark: true)
    public static let light = SupermuxZeronTheme(isDark: false)

    // MARK: Ink helpers bound to this appearance

    public func ink(_ a: Double) -> Color { ZeronInk.ink(a, dark: isDark) }
    public func hairline(_ a: Double) -> Color { ZeronInk.hairline(a, dark: isDark) }
    public func wash(_ a: Double) -> Color { ZeronInk.wash(a, dark: isDark) }

    // MARK: Surfaces

    /// `grey(6)` / `grey(0xff)`. The gate and empty-state ground.
    public var bg: Color { isDark ? .zeron(0x060606) : .zeron(0xFFFFFF) }
    /// `grey(13)` / `neutral(0.968)`.
    public var surface: Color { isDark ? .zeron(0x0D0D0D) : .zeron(0xF4F4F4) }
    /// `neutral(0.235)` / `neutral(0.940)`. The jump pill's opaque plate.
    public var surfaceRaised: Color { isDark ? .zeron(0x1E1E1E) : .zeron(0xEBEBEB) }
    /// `neutral(0.29)` / `neutral(0.900)` (§0.3 C5 — `#DEDEDE`, not `#E0E0E0`).
    /// Opaque pills BRIGHTEN on hover in dark and DARKEN in light; never swap
    /// the plate for a translucent wash, which makes the pill see-through.
    public var surfaceRaisedHover: Color { isDark ? .zeron(0x2B2B2B) : .zeron(0xDEDEDE) }
    /// `grey(0x0e)` / `grey(0xff)`. Tool cards and code blocks.
    public var surfaceCard: Color { isDark ? .zeron(0x0E0E0E) : .zeron(0xFFFFFF) }
    /// `grey(0x10)` / `grey(0xff)`.
    public var surfaceDialog: Color { isDark ? .zeron(0x101010) : .zeron(0xFFFFFF) }
    /// `grey(0x16)` / `grey(0xff)`.
    public var surfaceOverlay: Color { isDark ? .zeron(0x161616) : .zeron(0xFFFFFF) }

    // MARK: Interactive state

    /// `hsla(0,0,.92,.11)` / `hsla(0,0,.10,.06)`.
    public var elementHover: Color { isDark ? .zeron(0xEBEBEB, 0.11) : .zeron(0x1A1A1A, 0.06) }
    /// `hsla(0,0,.92,.16)` / `hsla(0,0,.10,.10)`.
    public var elementActive: Color { isDark ? .zeron(0xEBEBEB, 0.16) : .zeron(0x1A1A1A, 0.10) }

    // MARK: Edges

    /// The universal 1 pt hairline.
    public var border: Color { isDark ? .zeron(0xFFFFFF, 0.08) : .zeron(0x000000, 0.10) }
    /// Focused / raised edges.
    public var borderStrong: Color { isDark ? .zeron(0xFFFFFF, 0.14) : .zeron(0x000000, 0.17) }

    // MARK: Text

    /// `neutral(0.922)` / `neutral(0.25)`. 16.09:1 / 16.00:1 on each own `bg`.
    public var text: Color { isDark ? .zeron(0xE5E5E5) : .zeron(0x222222) }
    /// `neutral(0.708)` / `neutral(0.439)`. 7.81:1 / 7.80:1.
    public var textMuted: Color { isDark ? .zeron(0xA1A1A1) : .zeron(0x525252) }
    /// `neutral(0.556)` / `neutral(0.535)`. Held to a 4.1 contrast floor, not
    /// 4.5 — it is placeholder/disabled copy only.
    public var textFaint: Color { isDark ? .zeron(0x737373) : .zeron(0x6D6D6D) }
    /// `grey(0x98)` / `neutral(0.50)`.
    public var textDim: Color { isDark ? .zeron(0x989898) : .zeron(0x636363) }

    // MARK: Solid

    /// `neutral(0.922)` / `neutral(0.205)`.
    public var solid: Color { isDark ? .zeron(0xE5E5E5) : .zeron(0x171717) }
    /// `grey(0x0e)` / `neutral(0.985)`.
    public var onSolid: Color { isDark ? .zeron(0x0E0E0E) : .zeron(0xFAFAFA) }

    // MARK: Accent

    /// indigo-400 / indigo-600.
    public var accent: Color { isDark ? .zeron(0x7C86FF) : .zeron(0x4F39F6) }
    /// indigo-500 / indigo-600 (light collapses both onto the 600 step).
    public var accentStrong: Color { isDark ? .zeron(0x615FFF) : .zeron(0x4F39F6) }
    /// `neutral(0.985)` in BOTH appearances.
    public var onAccent: Color { .zeron(0xFAFAFA) }

    // MARK: Status

    /// red-400 / red-600.
    public var danger: Color { isDark ? .zeron(0xFF6467) : .zeron(0xE7000B) }
    /// red-300 / red-700.
    public var dangerMuted: Color { isDark ? .zeron(0xFFA2A2) : .zeron(0xC10007) }
    /// `oklch(.58,.16,25)` / `oklch(.51,.20,25)`.
    public var dangerStrong: Color { isDark ? .zeron(0xC74B47) : .zeron(0xBE1022) }
    /// amber-400 / amber-700. Dark clips its red channel hard — `#FFB900`, not
    /// a chroma-reduced value; zeron's gamut handling is a per-channel clamp.
    public var warning: Color { isDark ? .zeron(0xFFB900) : .zeron(0xBB4D00) }
    /// amber-200 / amber-800.
    public var warningMuted: Color { isDark ? .zeron(0xFEE685) : .zeron(0x973C00) }
    /// emerald-400 / emerald-600.
    public var success: Color { isDark ? .zeron(0x00D492) : .zeron(0x009966) }
    /// emerald-300 / emerald-700.
    public var successMuted: Color { isDark ? .zeron(0x5EE9B5) : .zeron(0x007A55) }
    /// pink-400 / pink-600. The streaming/busy indicator.
    public var busy: Color { isDark ? .zeron(0xFB64B6) : .zeron(0xE60076) }

    // MARK: Chrome

    /// Recessed picker header/footer strip; the `ZeronInk.band` field form.
    public var band: Color { ZeronInk.band(dark: isDark) }
    /// The RAW input fill. Prefer ``inputGlassBG()`` — that is what the
    /// composer pill actually paints.
    public var inputBG: Color { isDark ? .zeron(0xFFFFFF, 0.03) : .zeron(0xFFFFFF) }
    /// `hsla(.66,.6,.55,.35)` / `hsla(.66,.75,.62,.28)`. Text-selection wash.
    public var selection: Color { isDark ? .zeron(0x474DD1, 0.35) : .zeron(0x555BE7, 0.28) }
    /// Terminal-style block cursor wash.
    public var cursor: Color { isDark ? .zeron(0xFFFFFF, 0.35) : .zeron(0x000000, 0.55) }
    /// The 2 pt composer caret — a blue deliberately distinct from `accent`.
    public var caret: Color { isDark ? .zeron(0x7D81E8) : .zeron(0x181EBF) }

    // MARK: Code

    /// violet-300 / violet-700 (§0.3 C2/C3 — pixel-verified, NOT `#ddd6ff`
    /// or `#6e11b0`). Inline code and bubble mention chips.
    public var codeText: Color { isDark ? .zeron(0xC4B4FF) : .zeron(0x7008E7) }
    /// violet-400 @ 0.12 / violet-600 @ 0.10 (§0.3 C4).
    /// Composites to `#191524` over dark `bg` — pixel-verified.
    public var codeWash: Color { isDark ? .zeron(0xA684FF, 0.12) : .zeron(0x7F22FE, 0.10) }

    // MARK: Diff

    /// emerald-400 / emerald-600. **Full alpha** — this is the marker/number
    /// color. Row fills use ``diffAddWash()``.
    public var diffAdd: Color { isDark ? .zeron(0x00D492) : .zeron(0x009966) }
    /// red-400 / red-600. Full alpha; row fills use ``diffDelWash()``.
    public var diffDel: Color { isDark ? .zeron(0xFF6467) : .zeron(0xE7000B) }
    /// `hsla(.6,.35,.6,.05)` / `hsla(.6,.35,.35,.07)`.
    public var diffHunkBG: Color { isDark ? .zeron(0x7592BD, 0.05) : .zeron(0x3A5378, 0.07) }

    // MARK: Picker

    /// violet-400 / violet-600 — "the app's violet identity (the 'nice purple'
    /// family inline code wears), NOT the indigo `accent`: the indigo bar read
    /// blue against the glass."
    public var pickerPurple: Color { isDark ? .zeron(0xA684FF) : .zeron(0x7F22FE) }

    // MARK: - Derived functions (plan §1.2)

    /// Whether this platform composites over a real behind-window blur.
    ///
    /// macOS `true`, iOS `false` (§0.3 C13): nothing sits behind an iOS app to
    /// blur, so the iOS **shell** is opaque. iOS floating cards still use
    /// `.ultraThinMaterial`, which blurs *app* content — that is a card-level
    /// decision made by ``SupermuxZeronGlass``, not by this flag.
    public static let isGlassPlatform: Bool = {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }()

    /// Instance form of ``isGlassPlatform``. Glass-only recipes — backdrop
    /// blurs, translucent popover tints, the per-glyph edge fade — gate on this.
    public var isGlass: Bool { Self.isGlassPlatform }

    /// The frost tint painted OVER the blurred window background.
    ///
    /// Light glass is `grey(0xfa)`, deliberately NOT the surface's `#F4F4F4`:
    /// at high coverage the tint *is* the pane tone, and the darker grey read
    /// as a dingy slab next to the white content card.
    public func glass() -> Color {
        if isGlass { return isDark ? .zeron(0x080808, 0.80) : .zeron(0xFAFAFA, 0.80) }
        return surface
    }

    /// Hover wash for chrome sitting ON glass. Hover and selection share this
    /// exact fill; only the ring distinguishes them (see ``selectionRing()``).
    public func glassHover() -> Color { wash(isDark ? 0.11 : 0.06) }

    /// The translucent tint a floating card paints over its backdrop blur.
    /// Dark is zeron's `.glass-surface` menu tint verbatim, `oklch(0.33 0 0 / 34%)`.
    public func glassOverlay() -> Color {
        isDark ? .zeron(0x353535, 0.34) : .zeron(0xFFFFFF, 0.85)
    }

    /// **The composer pill fill.**
    ///
    /// Dark's 3 % white wash is glass-native in both branches. Light is pinned
    /// to white @ 0.30 on BOTH supported platforms: on macOS because the
    /// opaque white slab read as a solid rectangle in front of the blur, and on
    /// iOS by §0.3 C13 for the same reason against a white page. (zeron's
    /// opaque branch returns full-alpha `input_bg`; the plan overrides it.)
    public func inputGlassBG() -> Color {
        isDark ? .zeron(0xFFFFFF, 0.03) : .zeron(0xFFFFFF, 0.30)
    }

    /// Section-card fill. The opaque `surface` tone read as a harsh slab on the
    /// frost.
    ///
    /// NOTE: zeron gates this on `is_glass()` and returns opaque `surface` on
    /// opaque platforms (`theme.rs:564`). The plan's §1.2 derived table
    /// specifies 0.40 for both appearances with no platform split, because iOS
    /// cards sit on `.ultraThinMaterial` (C13) and want the same translucency.
    /// Plan wins.
    public func cardGlassBG() -> Color { surface.opacity(0.40) }

    /// The user message bubble plate (§0.3 C1 — `wash(0.08)`/`wash(0.04)`, NOT
    /// the screenshots' `#1E1E1E`, which is the older opaque `surface_raised`
    /// plate this value deliberately replaced). Composites to `#181818` dark /
    /// `#F6F6F6` light. No border, no shadow.
    public func userBubbleBG() -> Color { wash(isDark ? 0.08 : 0.04) }

    /// Selected tabs / session rows / space rows. Identical to ``glassHover()``.
    public func glassSelectedBG() -> Color { glassHover() }

    /// Selection INSIDE a floating card (menu rows, picker rail, chips).
    public func cardSelectedBG() -> Color { glassHover() }

    /// The selection ring.
    ///
    /// **Paint it as an inset 1 pt `strokeBorder`, never a `.shadow()`.** gpui's
    /// `BoxShadow { blur: 0, spread: 1, inset: true }` draws edges-only on TOP
    /// of the fill at zero layout cost; a SwiftUI drop shadow is a filled rect
    /// painted BEHIND the element, and behind a translucent fill it shows
    /// through as an opaque grey plate. Three light drop-shadow seats were
    /// tried in zeron and every one failed.
    ///
    /// Light is pinned at a FLAT 7 % black, deliberately **not**
    /// `hairline(0.09)` — 0.09 × 1.35 = 0.1215 outlined every selected chip in
    /// a dark box.
    public func selectionRing() -> Color {
        isDark ? .zeron(0xFFFFFF, 0.09) : .zeron(0x000000, 0.07)
    }

    /// Modal backdrop at zeron's `SCRIM_ALPHA_DARK` (0.60) ⇒ 0.32 light.
    public func scrim() -> Color {
        ZeronInk.scrim(SupermuxZeronMetrics.Theme.scrimAlphaDark, dark: isDark)
    }

    /// Added-diff ROW fill. Stored translucent and composited at render (§0.3
    /// C7): transcript diffs sit on the `ink(0.03)` chip card, the changes pane
    /// on `theme.bg`, and one baked hex cannot serve both.
    public func diffAddWash() -> Color {
        diffAdd.opacity(SupermuxZeronMetrics.Diff.rowWashAlpha)
    }

    /// Deleted-diff ROW fill. Same compositing rule as ``diffAddWash()``.
    public func diffDelWash() -> Color {
        diffDel.opacity(SupermuxZeronMetrics.Diff.rowWashAlpha)
    }

    // MARK: - Syntax

    /// The 24-field syntax palette for this appearance.
    public var syntax: SupermuxZeronSyntaxPalette {
        isDark ? .dark : .light
    }

    // MARK: - Appearance-independent

    /// The 3×3 working spinner's per-ROW tints — zeron's "sunrise" gradient
    /// sampled per row: cool blue top, amber middle, pink bottom.
    ///
    /// **Theme-independent by design**: `gradient_spinner` takes a `&Theme` and
    /// ignores it, so these are identical in light and dark. The tint is always
    /// painted at full saturation and only opacity animates — do NOT desaturate
    /// a dim cell.
    public static let gradientSpinnerRowTints: [Color] = [
        .zeron(0xB6D3EF), .zeron(0xEDB185), .zeron(0xF888A0),
    ]
}

// MARK: - Syntax palette

/// Tree-sitter capture kinds the renderer colors. 25 kinds over 24 fields —
/// ``embedded`` and ``punctuation`` deliberately share one field.
public enum SupermuxZeronHighlightKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case comment, keyword, string, stringSpecial, escape, number, boolean
    case type, typeBuiltin, constructor, function, functionBuiltin, macro
    case property, constant, variable, variableSpecial, parameter
    case `operator`, punctuation, embedded, tag, attribute, label, invalid
}

/// The 24-field syntax palette (`theme.rs:150`).
///
/// Built from five hue families plus `comment` and a `text` alias. Every hue is
/// passed through `git_graph_tone(c) { c.s *= 0.72 }` — **applied in HSL after
/// the oklch→sRGB conversion, not to the oklch chroma** — which softens lane
/// saturation "so the graph remains colorful without competing with content".
/// `comment` and the text aliases skip the tone.
///
/// Syntax runs are drawn at **full alpha**; plain code text is `text @ 0.92`
/// (``SupermuxZeronMetrics/Diff/codePlainAlpha``), so a highlighted token is
/// always slightly brighter than the code around it.
///
/// Invariant for any highlighter binding (plan R9): **highlighting changes
/// foreground color only** — never font, weight, style, wrapping, height or
/// scroll geometry.
public struct SupermuxZeronSyntaxPalette: Sendable, Equatable, Hashable {
    // The five tone-softened hue families + the two untoned aliases.
    public let indigo: Color
    public let pink: Color
    public let emerald: Color
    public let amber: Color
    public let red: Color
    public let commentTone: Color
    public let textTone: Color

    public init(
        indigo: Color,
        pink: Color,
        emerald: Color,
        amber: Color,
        red: Color,
        commentTone: Color,
        textTone: Color
    ) {
        self.indigo = indigo
        self.pink = pink
        self.emerald = emerald
        self.amber = amber
        self.red = red
        self.commentTone = commentTone
        self.textTone = textTone
    }

    /// `oklch` sources, post-`git_graph_tone`: indigo-400, pink-400,
    /// emerald-400, amber-400, red-400 (`danger`), `neutral(0.60)`,
    /// `neutral(0.922)`.
    public static let dark = SupermuxZeronSyntaxPalette(
        indigo: .zeron(0x8F96ED),
        pink: .zeron(0xE679B4),
        emerald: .zeron(0x1EB787),
        amber: .zeron(0xDBA924),
        red: .zeron(0xE9797C),
        commentTone: .zeron(0x808080),
        textTone: .zeron(0xE5E5E5)
    )

    /// Light sources drop to darker oklch steps so every kind clears its
    /// contrast floor on white: 3.0:1 for comment/operator/punctuation/embedded,
    /// 4.5:1 for everything else, on `bg` and both diff washes.
    public static let light = SupermuxZeronSyntaxPalette(
        indigo: .zeron(0x5754B4),
        pink: .zeron(0x8D2F58),
        emerald: .zeron(0x0F5B41),
        amber: .zeron(0x7C451E),
        red: .zeron(0xA61B20),
        commentTone: .zeron(0x5D5D5D),
        textTone: .zeron(0x222222)
    )

    // MARK: The 24 fields

    public var comment: Color { commentTone }
    public var keyword: Color { indigo }
    public var string: Color { emerald }
    public var stringSpecial: Color { pink }
    public var escape: Color { pink }
    public var number: Color { amber }
    public var boolean: Color { amber }
    public var typeName: Color { amber }
    public var typeBuiltin: Color { emerald }
    public var constructor: Color { amber }
    public var function: Color { indigo }
    public var functionBuiltin: Color { pink }
    public var macroName: Color { pink }
    public var property: Color { amber }
    public var constant: Color { emerald }
    public var variable: Color { textTone }
    public var variableSpecial: Color { pink }
    public var parameter: Color { textTone }
    public var operatorToken: Color { textTone }
    public var punctuation: Color { textTone }
    public var tag: Color { pink }
    public var attribute: Color { amber }
    public var label: Color { amber }
    public var invalid: Color { red }

    /// `SyntaxPalette::color` (`theme.rs:178`) — the kind → field mapping.
    public func color(for kind: SupermuxZeronHighlightKind) -> Color {
        switch kind {
        case .comment: comment
        case .keyword: keyword
        case .string: string
        case .stringSpecial: stringSpecial
        case .escape: escape
        case .number: number
        case .boolean: boolean
        case .type: typeName
        case .typeBuiltin: typeBuiltin
        case .constructor: constructor
        case .function: function
        case .functionBuiltin: functionBuiltin
        case .macro: macroName
        case .property: property
        case .constant: constant
        case .variable: variable
        case .variableSpecial: variableSpecial
        case .parameter: parameter
        case .operator: operatorToken
        // Embedded and Punctuation deliberately share one field.
        case .punctuation, .embedded: punctuation
        case .tag: tag
        case .attribute: attribute
        case .label: label
        case .invalid: invalid
        }
    }
}

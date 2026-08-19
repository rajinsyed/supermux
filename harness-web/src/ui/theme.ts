import type { HarnessTheme } from "../protocol/types";

/**
 * The glass design system's fallback themes, used until the native side pushes
 * the real `AgentSessionWebTheme`. The page is near-black (not pure black) in
 * dark and warm paper in light; every surface above it is a translucent veil so
 * the floating chrome — composer, working panel, framed views — reads as glass
 * over the scrolling transcript rather than as opaque slabs.
 */
export const defaultDarkTheme: HarnessTheme = {
  isDark: true,
  pageBackground: "#0f0f13",
  surfaceBackground: "rgba(255, 255, 255, 0.04)",
  surfaceElevatedBackground: "rgba(255, 255, 255, 0.07)",
  inputBackground: "rgba(255, 255, 255, 0.05)",
  border: "rgba(255, 255, 255, 0.08)",
  borderStrong: "rgba(255, 255, 255, 0.16)",
  text: "#ededf2",
  mutedText: "rgba(237, 237, 242, 0.56)",
  softText: "rgba(237, 237, 242, 0.78)",
  accent: "#7aa2f7",
  accentSoft: "rgba(122, 162, 247, 0.20)",
  danger: "#ff8d7e",
  shadow: "rgba(0, 0, 0, 0.42)"
};

export const defaultLightTheme: HarnessTheme = {
  isDark: false,
  pageBackground: "#fbfaf9",
  surfaceBackground: "rgba(20, 18, 16, 0.03)",
  surfaceElevatedBackground: "rgba(255, 255, 255, 0.92)",
  inputBackground: "#ffffff",
  border: "rgba(20, 18, 16, 0.10)",
  borderStrong: "rgba(20, 18, 16, 0.19)",
  text: "#1c1a18",
  mutedText: "rgba(28, 26, 24, 0.55)",
  softText: "rgba(28, 26, 24, 0.76)",
  accent: "#3a6ea5",
  accentSoft: "rgba(58, 110, 165, 0.14)",
  danger: "#b3261e",
  shadow: "rgba(20, 18, 16, 0.10)"
};

/**
 * The brand accent, vermilion rather than terracotta.
 *
 * The pane shipped with Claude's own soft orange (#d97757), which on a near-black
 * page read as a washed peach — the accent that should be the single loudest
 * mark in the interface was the quietest thing on the bottom bar. This is the
 * same hue family pushed toward RED (tomato/vermilion): it holds its identity at
 * 9% alpha behind a tint AND at full strength on a send button, which the old
 * value did not. Every ink tone derived from it is audited in
 * tests/contrast.test.ts.
 */
const CLAUDE = { r: 229, g: 72, b: 43 };

function overlay(isDark: boolean, alpha: number): string {
  return isDark ? `rgba(255, 255, 255, ${alpha})` : `rgba(0, 0, 0, ${alpha})`;
}

function claude(alpha: number): string {
  return `rgba(${CLAUDE.r}, ${CLAUDE.g}, ${CLAUDE.b}, ${alpha})`;
}

function parseRgb(color: string): [number, number, number] | undefined {
  const hex = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(color.trim());
  if (hex) {
    const value = hex[1];
    const full =
      value.length === 3
        ? value
            .split("")
            .map((c) => c + c)
            .join("")
        : value;
    return [
      Number.parseInt(full.slice(0, 2), 16),
      Number.parseInt(full.slice(2, 4), 16),
      Number.parseInt(full.slice(4, 6), 16)
    ];
  }
  const rgb = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/i.exec(color);
  if (rgb) return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])];
  return undefined;
}

/**
 * Secondary ink tiers, re-derived from the theme's own text color at alphas
 * that clear WCAG AA (4.5:1) for the 11–12.5px body text this pane sets on its
 * sunken surfaces. The native `mutedText` ships at 0.56–0.58, which lands under
 * the AA floor; these values are audited in tests/contrast.test.ts.
 */
function inkAlpha(theme: HarnessTheme, alpha: number): string {
  const ink = parseRgb(theme.text) ?? (theme.isDark ? [237, 237, 242] : [28, 26, 24]);
  return `rgba(${ink[0]}, ${ink[1]}, ${ink[2]}, ${alpha})`;
}

function pageRgb(theme: HarnessTheme): [number, number, number] {
  return parseRgb(theme.pageBackground) ?? (theme.isDark ? [15, 15, 19] : [247, 246, 244]);
}

/**
 * The dark theme's near-black.
 *
 * Round-5 finding: every dark surface was a WHITE veil over a near-black page
 * (`rgba(255,255,255,0.04)` and friends), which is the one operation that turns
 * black into grey. Stacked three deep — a card inside a panel inside the page —
 * the pane read as a washed grey slab, and the WKWebView is transparent over the
 * app's own window, so the native backdrop had nothing to show through.
 *
 * Dark surfaces are now this ink at an alpha instead: darker than the page,
 * translucent, so the native window (or the fallback page in a browser) reads
 * through them and the chrome sits BELOW the content in tone rather than above
 * it. Interaction highlights stay white — a black hover on near-black is
 * invisible — which is the same split shadcn's dark theme makes between
 * `background` and `accent`.
 */
const INK = { r: 8, g: 8, b: 11 };

function shade(alpha: number): string {
  return `rgba(${INK.r}, ${INK.g}, ${INK.b}, ${alpha})`;
}

/**
 * Popovers and menus float over transcript content, so they stay near-opaque —
 * a see-through menu lets the text underneath bleed into its rows. In dark that
 * is near-black at 0.95 over a backdrop blur (the macOS/shadcn menu material);
 * in light it is paper at 0.96.
 */
function popoverBackground(theme: HarnessTheme): string {
  if (theme.isDark) return shade(0.95);
  const base = pageRgb(theme);
  const lift = 8;
  const clamp = (value: number) => Math.max(0, Math.min(255, Math.round(value + lift)));
  return `rgba(${clamp(base[0])}, ${clamp(base[1])}, ${clamp(base[2])}, 0.96)`;
}

/**
 * The floating glass panels (composer pill, working panel, framed views).
 *
 * In dark these are the near-black ink at an alpha, so the panel is DARKER than
 * the transcript scrolling behind it and the native window shows through — the
 * previous build lifted the page colour by +10 and landed on the washed grey the
 * user rejected. Light keeps the page-derived paper tint, which is the correct
 * direction there.
 */
function glassPanel(theme: HarnessTheme, alpha: number): string {
  if (theme.isDark) return shade(alpha);
  const base = pageRgb(theme);
  const clamp = (value: number) => Math.max(0, Math.min(255, Math.round(value + 4)));
  return `rgba(${clamp(base[0])}, ${clamp(base[1])}, ${clamp(base[2])}, ${alpha})`;
}

export function themeVariables(theme: HarnessTheme): Record<string, string> {
  const dark = theme.isDark;
  const page = theme.pageBackground === "transparent" ? "transparent" : theme.pageBackground;
  return {
    "--page-bg": page,

    /* Surfaces. `--surface` is the in-flow veil (user bubble, open tool body);
       `--panel` is the floating glass the dock chrome and framed views wear.
       In DARK both are near-black ink at an alpha rather than a white veil: a
       white veil over near-black is exactly the washed grey the round-5 report
       named, and it left nothing for the transparent WKWebView to show through.
       Light keeps its ink veil, which darkens paper correctly. */
    "--surface": dark ? shade(0.34) : theme.surfaceBackground,
    "--surface-raised": dark ? shade(0.5) : theme.surfaceElevatedBackground,
    /* Interaction highlights stay WHITE in dark — a black hover on near-black
       is invisible. Same split shadcn's dark theme makes between `background`
       (near-black) and `accent` (a lifted neutral). */
    "--surface-hover": overlay(dark, dark ? 0.06 : 0.035),
    "--surface-active": overlay(dark, dark ? 0.1 : 0.06),
    "--surface-sunken": dark ? shade(0.4) : overlay(false, 0.035),
    "--panel": glassPanel(theme, dark ? 0.72 : 0.8),
    "--panel-solid": popoverBackground(theme),
    "--popover-bg": popoverBackground(theme),
    "--glass-blur": "blur(18px) saturate(1.5)",
    "--input-bg": dark ? shade(0.42) : theme.inputBackground,

    /* Hairlines. Glass panels wear the faint line; strong marks interaction.
       Dark borders lift slightly (0.08 → 0.10) because the surfaces under them
       are darker now and a 0.08 hairline on near-black had nothing to separate
       from. This is shadcn's 1px-crisp-edge grammar, not a heavier stroke. */
    "--border": dark ? "rgba(255, 255, 255, 0.10)" : theme.border,
    "--border-strong": dark ? "rgba(255, 255, 255, 0.18)" : theme.borderStrong,
    "--border-faint": overlay(dark, dark ? 0.06 : 0.05),

    /* Ink tiers, audited against the darkest bed each lands on. */
    "--text": theme.text,
    "--text-soft": inkAlpha(theme, dark ? 0.84 : 0.82),
    "--text-muted": inkAlpha(theme, dark ? 0.72 : 0.7),
    "--text-faint": inkAlpha(theme, dark ? 0.62 : 0.64),

    /* Code and terminal beds. The transcript terminal stays dark in both
       themes; the QUIET terminal (background-task tails in light chrome)
       follows the page instead. */
    "--code-bg": dark ? "rgba(0, 0, 0, 0.30)" : "rgba(20, 18, 16, 0.045)",

    /* The INLINE chip's bed, split from the code BLOCK's (round-7 item 5).
     *
     * The chip reused `--code-bg`, which in dark is black at 30% — a bed
     * designed to sink a code block inside a card that already has a surface
     * under it. An inline chip has no such surface: it sits on the bare
     * transcript, which is near-black, so a darker-than-black veil rendered as
     * no bed at all and the chip was carried entirely by its border. Taking the
     * border off (the thing that made it read as a button in a sentence) left
     * nothing, which is why this needs its own token rather than a tweak.
     *
     * In DARK it is therefore a white veil — the one direction that separates
     * from near-black — kept low enough to stay a tint rather than a slab. In
     * LIGHT the ink veil is already the correct direction and only lifts
     * slightly, since it now carries the chip alone. Both are audited under the
     * chip's own ink (`--claude`) in tests/contrast.test.ts. */
    "--inline-code-bg": dark ? "rgba(255, 255, 255, 0.075)" : "rgba(20, 18, 16, 0.055)",
    "--code-header-bg": dark ? "rgba(0, 0, 0, 0.20)" : "rgba(20, 18, 16, 0.028)",
    "--terminal-bg": dark ? "rgba(0, 0, 0, 0.38)" : "rgba(24, 22, 20, 0.94)",
    "--terminal-fg": "rgba(248, 246, 244, 0.94)",
    "--terminal-muted": "rgba(248, 246, 244, 0.68)",
    "--terminal-error": "#ffa79a",
    "--terminal-chrome": "rgba(255, 255, 255, 0.06)",
    "--terminal-border": "rgba(255, 255, 255, 0.10)",
    "--terminal-quiet-bg": dark ? "rgba(0, 0, 0, 0.30)" : "rgba(20, 18, 16, 0.06)",
    "--terminal-quiet-fg": dark ? "rgba(248, 246, 244, 0.94)" : "#1c1a18",
    "--terminal-quiet-muted": dark ? "rgba(248, 246, 244, 0.68)" : "#3b3936",
    "--terminal-quiet-error": dark ? "#ffa79a" : "#a3221b",
    "--terminal-quiet-chrome": dark ? "rgba(255, 255, 255, 0.05)" : "rgba(20, 18, 16, 0.04)",
    "--terminal-quiet-chrome-hover": dark
      ? "rgba(255, 255, 255, 0.09)"
      : "rgba(20, 18, 16, 0.08)",

    /* Vermilion: the single brand accent, split into a text tone that clears AA
       and chrome tones that stay vivid. Dark gets a lighter salmon-red so it
       clears AA on near-black; light gets a deep brick so it clears AA on paper
       AND stays legible on its own 13% tint. */
    "--accent": theme.accent,
    "--accent-soft": theme.accentSoft,
    "--claude": dark ? "#ff8f75" : "#b8391b",
    "--claude-strong": dark ? "#ff7a5c" : "#d1401f",
    "--claude-btn": dark ? "#ffa693" : "#a63317",
    "--claude-btn-hover": dark ? "#ffbfb0" : "#8c2a12",
    "--on-claude": dark ? "#26100b" : "#ffffff",
    "--on-claude-chip": dark ? "rgba(0, 0, 0, 0.20)" : "rgba(0, 0, 0, 0.22)",
    "--claude-soft": claude(dark ? 0.18 : 0.13),
    "--claude-faint": claude(dark ? 0.09 : 0.07),
    "--claude-border": claude(dark ? 0.4 : 0.34),
    "--focus-ring": claude(dark ? 0.5 : 0.4),

    /* The shimmer's two tones (see `.shimmer` in base.css).
     *
     * The sweep is a gradient between them, so the DIMMER of the two is what
     * most of the glyphs wear most of the time — it is the resting tone of the
     * text, not a highlight, and it is audited at AA in tests/contrast.test.ts
     * exactly like every other ink tier. `--shimmer-sheen` is the crest: the
     * accent, so the one animated thing in the pane is unmistakably the brand's
     * and not a grey pulse. */
    "--shimmer-base": inkAlpha(theme, dark ? 0.62 : 0.64),
    "--shimmer-sheen": dark ? "#ff8f75" : "#b8391b",

    /* Status families, each with a text tone, a dot tone, and a soft tint. */
    "--danger": dark ? "#ff9d8e" : "#a3221b",
    "--danger-dot": theme.danger,
    "--danger-hover": dark ? "#ffb0a3" : "#8a1c16",
    "--on-danger": dark ? "#2a1512" : "#ffffff",
    "--on-danger-chip": dark ? "rgba(255, 255, 255, 0.34)" : "rgba(0, 0, 0, 0.22)",
    "--danger-soft": dark ? "rgba(255, 141, 126, 0.16)" : "rgba(179, 38, 30, 0.10)",
    "--danger-border": dark ? "rgba(255, 141, 126, 0.34)" : "rgba(179, 38, 30, 0.26)",
    "--success": dark ? "#8ed3a8" : "#1e6b41",
    "--success-dot": dark ? "#7ec99a" : "#2e7d4f",
    "--success-soft": dark ? "rgba(126, 201, 154, 0.15)" : "rgba(46, 125, 79, 0.10)",
    "--warning": dark ? "#ecc47d" : "#7d5300",
    "--warning-dot": dark ? "#e8bd6d" : "#9a6b0f",
    "--warning-soft": dark ? "rgba(232, 189, 109, 0.15)" : "rgba(154, 107, 15, 0.10)",
    "--violet": dark ? "#c0abee" : "#5b3fa3",
    "--violet-dot": dark ? "#b39ce8" : "#6d4fb8",
    "--violet-soft": dark ? "rgba(179, 156, 232, 0.15)" : "rgba(109, 79, 184, 0.10)",

    /* Elevation, by EDGE rather than by shadow.
     *
     * The floating chrome used to carry a wide dark drop shadow (0 12px 40px)
     * under every panel, card, popover, and framed view. Stacked — the dock is
     * five islands deep and a tool card sits inside a turn inside a transcript
     * — those pooled into grey haloes behind most of the pane, which is what
     * "weird back shadows on them" names. Separation here comes from the
     * hairline border plus the backdrop blur; the glass already sits visibly
     * off the page without being lit from above.
     *
     * What survives is the inset top line: the one-pixel highlight where a
     * panel catches the light, and the thing that separates "translucent
     * rectangle" from "pane of glass". It costs nothing behind the element.
     */
    "--shadow": theme.shadow,
    "--shadow-lifted": "none",
    "--shadow-panel": dark
      ? "inset 0 1px 0 rgba(255, 255, 255, 0.06)"
      : "inset 0 1px 0 rgba(255, 255, 255, 0.65)",
    /* Modals are the one exception, and only just: a dialog floats over a
       dimming scrim rather than over readable content, so it needs no lift to
       be legible — but the scrim's own edge is soft, and a very faint contact
       shadow is what keeps the panel from looking pasted onto it. */
    "--shadow-modal": dark
      ? "0 4px 14px rgba(0, 0, 0, 0.22)"
      : "0 4px 14px rgba(20, 18, 16, 0.10)",
    /* The SECOND exception, and the reason the round-4 menus read as flat
       rectangles pasted onto the transcript: a popover is the one surface with
       nothing behind it but readable text, and a hairline alone cannot say
       "this is in front". shadcn's layered popover shadow — a tight contact
       shadow under a wide ambient one — is what gives a menu its lift without
       the grey halo a single wide blur pooled under the old chrome. It is
       declared ONCE and worn by every floating surface in the kit. */
    "--shadow-popover": dark
      ? "0 1px 2px rgba(0, 0, 0, 0.45), 0 8px 24px -6px rgba(0, 0, 0, 0.65)"
      : "0 1px 2px rgba(20, 18, 16, 0.07), 0 8px 24px -6px rgba(20, 18, 16, 0.16)",
    "--scrim": dark ? "rgba(0, 0, 0, 0.58)" : "rgba(20, 18, 16, 0.34)",

    /* Diff and syntax, audited against the tinted diff beds in
       tests/contrast.test.ts — the flat code surface is not the worst case. */
    "--diff-add-bg": dark ? "rgba(126, 201, 154, 0.13)" : "rgba(46, 125, 79, 0.10)",
    "--diff-add-fg": dark ? "#9ad9b2" : "#1e683d",
    "--diff-del-bg": dark ? "rgba(255, 141, 126, 0.13)" : "rgba(179, 38, 30, 0.09)",
    "--diff-del-fg": dark ? "#ffa79a" : "#a1231c",
    "--diff-gutter": dark ? "rgba(237, 237, 242, 0.60)" : "rgba(28, 26, 24, 0.68)",
    "--hl-keyword": dark ? "#c89ae0" : "#7246a1",
    "--hl-string": dark ? "#9ad9b2" : "#1e683d",
    "--hl-number": dark ? "#e8bd6d" : "#79540c",
    "--hl-comment": dark ? "rgba(237, 237, 242, 0.62)" : "rgba(28, 26, 24, 0.72)",
    "--hl-function": dark ? "#7aa2f7" : "#2b5c9a",
    "--hl-type": dark ? "#e2896c" : "#924425",
    "--hl-attr": dark ? "#8fd3d0" : "#0e6663"
  };
}

export function applyThemeVariables(root: HTMLElement, theme: HarnessTheme): void {
  const vars = themeVariables(theme);
  for (const [name, value] of Object.entries(vars)) root.style.setProperty(name, value);
  root.dataset.theme = theme.isDark ? "dark" : "light";
  root.dataset.transparent = theme.pageBackground === "transparent" ? "true" : "false";
}

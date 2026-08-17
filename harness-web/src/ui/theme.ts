import type { HarnessTheme } from "../protocol/types";

export const defaultDarkTheme: HarnessTheme = {
  isDark: true,
  pageBackground: "#16161a",
  surfaceBackground: "rgba(255, 255, 255, 0.035)",
  surfaceElevatedBackground: "rgba(255, 255, 255, 0.062)",
  inputBackground: "rgba(255, 255, 255, 0.05)",
  border: "rgba(255, 255, 255, 0.085)",
  borderStrong: "rgba(255, 255, 255, 0.16)",
  text: "#eceaf0",
  mutedText: "rgba(236, 234, 240, 0.56)",
  softText: "rgba(236, 234, 240, 0.78)",
  accent: "#7aa2f7",
  accentSoft: "rgba(122, 162, 247, 0.20)",
  danger: "#ff8d7e",
  shadow: "rgba(0, 0, 0, 0.36)"
};

export const defaultLightTheme: HarnessTheme = {
  isDark: false,
  pageBackground: "#fbfaf9",
  surfaceBackground: "rgba(20, 18, 16, 0.028)",
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

const CLAUDE = { r: 217, g: 119, b: 87 };

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
 * Popovers must be fully opaque: they float over transcript content, and a
 * translucent surface makes text underneath bleed through. The native theme
 * only ships alpha-blended surfaces, so derive an opaque tone from the page
 * background (falling back to a neutral when it is "transparent").
 */
/**
 * The native theme ships `mutedText` at 0.58 alpha and `softText` at 0.78,
 * tuned for the markdown panels. In this pane those tokens carry 10.5–12.5px
 * body text over sunken surfaces, where 0.58 lands at 3.8:1 — under the 4.5:1
 * AA floor for small text. Re-derive the secondary tiers from the theme's own
 * ink at alphas that clear AA on the darkest surface the pane paints.
 */
function inkAlpha(theme: HarnessTheme, alpha: number): string {
  const ink = parseRgb(theme.text) ?? (theme.isDark ? [236, 234, 240] : [28, 26, 24]);
  return `rgba(${ink[0]}, ${ink[1]}, ${ink[2]}, ${alpha})`;
}

function popoverBackground(theme: HarnessTheme): string {
  const base = parseRgb(theme.pageBackground) ?? (theme.isDark ? [22, 22, 26] : [251, 250, 249]);
  const lift = theme.isDark ? 12 : -6;
  const clamp = (value: number) => Math.max(0, Math.min(255, Math.round(value + lift)));
  return `rgb(${clamp(base[0])}, ${clamp(base[1])}, ${clamp(base[2])})`;
}

export function themeVariables(theme: HarnessTheme): Record<string, string> {
  const dark = theme.isDark;
  const page = theme.pageBackground === "transparent" ? "transparent" : theme.pageBackground;
  return {
    "--page-bg": page,
    "--surface": theme.surfaceBackground,
    "--surface-raised": theme.surfaceElevatedBackground,
    "--popover-bg": popoverBackground(theme),
    "--surface-hover": overlay(dark, dark ? 0.045 : 0.032),
    "--surface-active": overlay(dark, dark ? 0.075 : 0.055),
    "--surface-sunken": overlay(dark, dark ? 0.13 : 0.035),
    "--input-bg": theme.inputBackground,
    "--code-bg": dark ? "rgba(0, 0, 0, 0.30)" : "rgba(20, 18, 16, 0.045)",
    "--code-header-bg": dark ? "rgba(0, 0, 0, 0.20)" : "rgba(20, 18, 16, 0.028)",
    // The terminal is a dark surface in BOTH themes, so everything drawn on it
    // derives from the terminal palette rather than the page palette.
    "--terminal-bg": dark ? "rgba(0, 0, 0, 0.38)" : "rgba(24, 22, 20, 0.94)",
    "--terminal-fg": "rgba(248, 246, 244, 0.94)",
    "--terminal-muted": "rgba(248, 246, 244, 0.68)",
    "--terminal-error": "#ffa79a",
    "--terminal-chrome": "rgba(255, 255, 255, 0.06)",
    "--terminal-border": "rgba(255, 255, 255, 0.10)",
    "--border": theme.border,
    "--border-strong": theme.borderStrong,
    "--border-faint": overlay(dark, dark ? 0.05 : 0.05),
    "--text": theme.text,
    "--text-soft": inkAlpha(theme, dark ? 0.84 : 0.82),
    "--text-muted": inkAlpha(theme, dark ? 0.72 : 0.7),
    // Content, not decoration: every consumer renders 10–12px text that must
    // clear WCAG AA against the surface behind it.
    "--text-faint": inkAlpha(theme, dark ? 0.62 : 0.64),
    "--accent": theme.accent,
    "--accent-soft": theme.accentSoft,
    // Accents split into a TEXT tone and a chrome tone. The chrome tones stay
    // vivid for borders, carets, dots, and fills; the text tones are darkened
    // (light) / lightened (dark) until they clear AA on the sunken and soft-tint
    // surfaces they actually land on, since each is used for real label text.
    "--claude": dark ? "#eb9d83" : "#ad4a27",
    "--claude-strong": dark ? "#f0a184" : "#d97757",
    "--claude-btn": dark ? "#f0a184" : "#b0502c",
    "--claude-btn-hover": dark ? "#f6b39a" : "#994026",
    "--on-claude": dark ? "#231a16" : "#ffffff",
    "--on-claude-chip": dark ? "rgba(255, 255, 255, 0.34)" : "rgba(0, 0, 0, 0.22)",
    // Keyboard focus is where the user IS, so it must read at least as strongly
    // as hover, which supplies a full surface + border + colour change. The ring
    // is drawn as a box-shadow halo so it survives on tinted and dark surfaces
    // alike, paired with the outline in base.css.
    "--focus-ring": claude(dark ? 0.55 : 0.45),
    "--claude-soft": claude(dark ? 0.18 : 0.13),
    "--claude-faint": claude(dark ? 0.09 : 0.07),
    "--claude-border": claude(dark ? 0.34 : 0.3),
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
    "--shadow": theme.shadow,
    "--shadow-lifted": dark ? "0 8px 26px rgba(0, 0, 0, 0.42)" : "0 8px 26px rgba(20, 18, 16, 0.10)",
    // A modal scrim cannot be derived from the page background: the pane
    // supports a TRANSPARENT page (it sits over the workspace), where any
    // page-derived tint is nothing at all and the transcript shows straight
    // through the dialog. Ink in both themes, heavier in light because the
    // content it must suppress is itself light.
    "--scrim": dark ? "rgba(0, 0, 0, 0.58)" : "rgba(20, 18, 16, 0.34)",
    "--shadow-modal": dark
      ? "0 18px 48px rgba(0, 0, 0, 0.58)"
      : "0 18px 48px rgba(20, 18, 16, 0.22)",
    "--diff-add-bg": dark ? "rgba(126, 201, 154, 0.13)" : "rgba(46, 125, 79, 0.10)",
    "--diff-add-fg": dark ? "#9ad9b2" : "#1e683d",
    "--diff-del-bg": dark ? "rgba(255, 141, 126, 0.13)" : "rgba(179, 38, 30, 0.09)",
    "--diff-del-fg": dark ? "#ffa79a" : "#a1231c",
    "--diff-gutter": dark ? "rgba(236, 234, 240, 0.60)" : "rgba(28, 26, 24, 0.68)",
    // Syntax tokens land on THREE surfaces, not one: the flat code background
    // and the two diff tints, which are the darker worst case in light mode.
    // Each light value is derived to clear AA against all three (see
    // tests/contrast.test.ts) — the flat surface alone is not the bar.
    "--hl-keyword": dark ? "#c89ae0" : "#7246a1",
    "--hl-string": dark ? "#9ad9b2" : "#1e683d",
    "--hl-number": dark ? "#e8bd6d" : "#79540c",
    "--hl-comment": dark ? "rgba(236, 234, 240, 0.62)" : "rgba(28, 26, 24, 0.72)",
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

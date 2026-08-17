import { describe, expect, test } from "bun:test";
import { defaultDarkTheme, defaultLightTheme, themeVariables } from "../src/ui/theme";

type RGB = [number, number, number];

const AA_SMALL = 4.5;

function parse(color: string): RGB {
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
  const rgb = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,\s/]+([\d.]+))?/i.exec(color);
  if (!rgb) throw new Error(`unparsable color: ${color}`);
  return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])];
}

function alphaOf(color: string): number {
  const rgba = /rgba\(\s*[\d.]+[,\s]+[\d.]+[,\s]+[\d.]+[,\s/]+([\d.]+)/i.exec(color);
  return rgba ? Number(rgba[1]) : 1;
}

/** Composite a possibly-translucent CSS color over an opaque bed. */
function composite(color: string, bed: RGB): RGB {
  const fg = parse(color);
  const a = alphaOf(color);
  return [0, 1, 2].map((i) => fg[i] * a + bed[i] * (1 - a)) as RGB;
}

function luminance(c: RGB): number {
  const channels = c.map((v) => {
    const x = v / 255;
    return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

function ratio(a: RGB, b: RGB): number {
  const l1 = luminance(a);
  const l2 = luminance(b);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}

/**
 * Rebuilds the real stack of composited surfaces a token lands on. The flat code
 * background is NOT the worst case — the diff tints painted over it are — so a
 * palette audit that only checks the flat surface passes while the tinted rows
 * fail, which is exactly how round 1 shipped unreadable `def`/`print`/numbers.
 */
function surfaces(isDark: boolean) {
  const vars = themeVariables(isDark ? defaultDarkTheme : defaultLightTheme);
  const page = parse(vars["--page-bg"]);
  const card = composite(vars["--surface"], page);
  const raised = composite(vars["--surface-raised"], page);
  const beds: Record<string, RGB> = {};
  for (const [name, base] of [
    ["card", card],
    ["raised", raised]
  ] as const) {
    const code = composite(vars["--code-bg"], base);
    beds[`${name}:code`] = code;
    beds[`${name}:diffAdd`] = composite(vars["--diff-add-bg"], code);
    beds[`${name}:diffDel`] = composite(vars["--diff-del-bg"], code);
    beds[`${name}:terminal`] = composite(vars["--terminal-bg"], base);
  }
  // The error-tinted card is a distinct bed for terminal output: a failed Bash
  // card is exactly where ANSI red and blue carry the most meaning.
  const errorCard = composite(vars["--danger-soft"], page);
  beds["error:terminal"] = composite(vars["--terminal-bg"], errorCard);
  return { vars, beds };
}

const HLJS_TOKENS = [
  "--hl-keyword",
  "--hl-string",
  "--hl-number",
  "--hl-comment",
  "--hl-function",
  "--hl-type",
  "--hl-attr"
] as const;

const CODE_BEDS = ["code", "diffAdd", "diffDel"];

describe("syntax highlighting contrast", () => {
  for (const isDark of [true, false]) {
    const label = isDark ? "dark" : "light";
    const { vars, beds } = surfaces(isDark);

    for (const token of HLJS_TOKENS) {
      test(`${token} clears AA on every code surface (${label})`, () => {
        const failures: string[] = [];
        for (const [name, bed] of Object.entries(beds)) {
          if (!CODE_BEDS.some((kind) => name.endsWith(kind))) continue;
          const value = ratio(composite(vars[token], bed), bed);
          if (value < AA_SMALL) failures.push(`${name}=${value.toFixed(2)}`);
        }
        expect(failures).toEqual([]);
      });
    }

    test(`diff foregrounds clear AA on their own tints (${label})`, () => {
      const pairs: Array<[string, string]> = [
        ["--diff-add-fg", "diffAdd"],
        ["--diff-del-fg", "diffDel"],
        ["--diff-gutter", "code"]
      ];
      const failures: string[] = [];
      for (const [token, kind] of pairs) {
        for (const [name, bed] of Object.entries(beds)) {
          if (!name.endsWith(kind)) continue;
          const value = ratio(composite(vars[token], bed), bed);
          if (value < AA_SMALL) failures.push(`${label} ${token} on ${name}=${value.toFixed(2)}`);
        }
      }
      expect(failures).toEqual([]);
    });
  }
});

// The ANSI palette is a single :root block shared by both themes because the
// terminal is a DARK surface in both — so it is audited against every terminal
// bed either theme can produce, plain and error-tinted.
const ANSI = {
  "--ansi-black": "#959599",
  "--ansi-red": "#e77269",
  "--ansi-green": "#4fa96b",
  "--ansi-yellow": "#c98b1f",
  "--ansi-blue": "#6b98d0",
  "--ansi-magenta": "#b482ce",
  "--ansi-cyan": "#3fa3a2",
  "--ansi-white": "#cfcdd4",
  "--ansi-bright-black": "#94949c",
  "--ansi-bright-red": "#ff8d7e",
  "--ansi-bright-green": "#7ec99a",
  "--ansi-bright-yellow": "#e8bd6d",
  "--ansi-bright-blue": "#7aa2f7",
  "--ansi-bright-magenta": "#c89ae0",
  "--ansi-bright-cyan": "#8fd3d0",
  "--ansi-bright-white": "#f2f0f5"
} as const;

describe("ANSI terminal palette contrast", () => {
  const terminalBeds: Record<string, RGB> = {};
  for (const isDark of [true, false]) {
    const { beds } = surfaces(isDark);
    for (const [name, bed] of Object.entries(beds)) {
      if (name.endsWith("terminal")) terminalBeds[`${isDark ? "dark" : "light"}:${name}`] = bed;
    }
  }

  for (const [token, color] of Object.entries(ANSI)) {
    test(`${token} clears AA on every terminal surface`, () => {
      const failures: string[] = [];
      for (const [name, bed] of Object.entries(terminalBeds)) {
        const value = ratio(parse(color), bed);
        if (value < AA_SMALL) failures.push(`${name}=${value.toFixed(2)}`);
      }
      expect(failures).toEqual([]);
    });
  }

  test("the CSS palette and the audited palette are the same values", async () => {
    const css = await Bun.file(
      new URL("../src/styles/content.css", import.meta.url).pathname
    ).text();
    for (const [token, color] of Object.entries(ANSI)) {
      expect(css).toContain(`${token}: ${color};`);
    }
  });
});

describe("terminal chrome contrast", () => {
  for (const isDark of [true, false]) {
    const label = isDark ? "dark" : "light";
    const { vars, beds } = surfaces(isDark);
    test(`terminal foreground and muted chrome clear AA (${label})`, () => {
      const failures: string[] = [];
      for (const [name, bed] of Object.entries(beds)) {
        if (!name.endsWith("terminal")) continue;
        for (const token of ["--terminal-fg", "--terminal-muted", "--terminal-error"]) {
          const value = ratio(composite(vars[token], bed), bed);
          if (value < AA_SMALL) failures.push(`${token} on ${name}=${value.toFixed(2)}`);
        }
      }
      expect(failures).toEqual([]);
    });
  }
});

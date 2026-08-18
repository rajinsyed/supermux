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

/**
 * The QUOTED terminal's beds — a background task's output tail, which is the one
 * place terminal output is painted inside the DOCK rather than inside a Bash
 * card. In light it is a light surface (the dark slab was the heaviest object on
 * a pale pane, for content that is by construction peripheral), so it takes a
 * light-tuned ANSI palette, and both palettes have to be audited against the
 * beds they actually land on.
 *
 * Two beds because the tail appears in two places: a strip row (raised, or the
 * claude tint while the task runs) and inside a Bash card's disclosure.
 */
function quietTerminalBeds(isDark: boolean): { vars: Record<string, string>; beds: Record<string, RGB> } {
  const { vars } = surfaces(isDark);
  const page = parse(vars["--page-bg"]);
  const raised = composite(vars["--surface-raised"], page);
  const running = composite(vars["--claude-faint"], page);
  return {
    vars,
    beds: {
      "row:quiet": composite(vars["--terminal-quiet-bg"], raised),
      "running-row:quiet": composite(vars["--terminal-quiet-bg"], running),
      "card:quiet": composite(vars["--terminal-quiet-bg"], composite(vars["--surface"], page))
    }
  };
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

/**
 * The light-theme ANSI set, for the quoted output tail alone.
 *
 * The tail used to paint the full-strength dark terminal inside the light dock
 * — the heaviest object on the pane, for peripheral output, under a light strip
 * and above a light composer. Making its bed light is only half the fix: the
 * palette above is derived for a DARK bed and every one of its hues fails on a
 * pale one, so the tail re-points `--ansi-*` at this set. Audited here exactly
 * as the dark set is audited on its own beds, or the fix trades a heavy slab for
 * unreadable output.
 */
const ANSI_LIGHT = {
  "--ansi-black": "#5c5c63",
  "--ansi-red": "#a3231c",
  "--ansi-green": "#1e683d",
  "--ansi-yellow": "#79540c",
  "--ansi-blue": "#2b5c9a",
  "--ansi-magenta": "#7246a1",
  "--ansi-cyan": "#0e6663",
  "--ansi-white": "#4a4a50",
  "--ansi-bright-black": "#595960",
  "--ansi-bright-red": "#8f1c16",
  "--ansi-bright-green": "#175733",
  "--ansi-bright-yellow": "#6a4a0a",
  "--ansi-bright-blue": "#24508a",
  "--ansi-bright-magenta": "#623a8c",
  "--ansi-bright-cyan": "#0b5654",
  "--ansi-bright-white": "#2a2a2f"
} as const;

describe("the quoted output tail is readable on its own bed", () => {
  test("the light tail is a LIGHT surface, not a dark slab in a light dock", () => {
    const light = quietTerminalBeds(false);
    const page = parse(light.vars["--page-bg"]);
    for (const [name, bed] of Object.entries(light.beds)) {
      // Within striking distance of the page it sits on, rather than the near
      // black (luminance ~0.011) the dark slab painted there.
      expect(luminance(bed)).toBeGreaterThan(luminance(page) * 0.7);
    }
  });

  test("the dark tail is still the terminal", () => {
    const dark = quietTerminalBeds(true);
    for (const bed of Object.values(dark.beds)) expect(luminance(bed)).toBeLessThan(0.06);
  });

  for (const isDark of [true, false]) {
    const label = isDark ? "dark" : "light";
    const { vars, beds } = quietTerminalBeds(isDark);
    const palette = isDark ? ANSI : ANSI_LIGHT;

    test(`every ANSI colour clears AA on every quoted-tail bed (${label})`, () => {
      const failures: string[] = [];
      for (const [token, color] of Object.entries(palette)) {
        for (const [name, bed] of Object.entries(beds)) {
          const value = ratio(parse(color), bed);
          if (value < AA_SMALL) failures.push(`${token} on ${name}=${value.toFixed(2)}`);
        }
      }
      expect(failures).toEqual([]);
    });

    test(`the tail's own ink and chrome clear AA (${label})`, () => {
      const failures: string[] = [];
      for (const token of [
        "--terminal-quiet-fg",
        "--terminal-quiet-muted",
        "--terminal-quiet-error"
      ]) {
        for (const [name, bed] of Object.entries(beds)) {
          const value = ratio(composite(vars[token], bed), bed);
          if (value < AA_SMALL) failures.push(`${token} on ${name}=${value.toFixed(2)}`);
        }
      }
      expect(failures).toEqual([]);
    });
  }

  test("the light palette in the sheet is the one audited here", async () => {
    const css = await Bun.file(
      new URL("../src/styles/content.css", import.meta.url).pathname
    ).text();
    const scoped = /:root\[data-theme="light"\] \.task-output \{([^}]*)\}/.exec(css);
    expect(scoped).not.toBeNull();
    for (const [token, color] of Object.entries(ANSI_LIGHT)) {
      expect(scoped![1]).toContain(`${token}: ${color};`);
    }
  });
});

/**
 * The failure this suite kept missing: a token that clears AA on its own, then
 * knocked below it by an `opacity` on the SAME element. `.divider-sub` was
 * `--text-faint` × 0.72 = 2.95:1 in light, and `.banner-detail` was the warning
 * amber × 0.78 = 3.53:1 on its own tint. Neither is a syntax, diff, or ANSI
 * token, so nothing above audited them. Every rule in the sheets that dims text
 * with `opacity` is now composited at its real alpha against the surface it
 * lands on.
 */
const SHEETS = [
  "base.css",
  "cards.css",
  "content.css",
  "dock.css",
  "layout.css",
  "modal.css",
  "tools.css",
  "transcript.css"
];

async function sheet(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

/**
 * `.selector { color: var(--text-*); opacity: N }` — a text tier dimmed a second
 * time. `opacity: 0` is excluded: that is a hover reveal, not a rendered tone.
 * Icon and syntax tokens are out of scope here; they are audited on their own
 * beds above and by the ANSI/hljs suites.
 */
async function attenuatedTextRules(): Promise<Array<{ where: string; token: string; alpha: number }>> {
  const found: Array<{ where: string; token: string; alpha: number }> = [];
  for (const name of SHEETS) {
    const css = await sheet(name);
    for (const match of css.matchAll(/(?:^|\n)([^{}\n]+)\{([^}]*)\}/g)) {
      const body = match[2];
      const alpha = /(?<!-)opacity:\s*([\d.]+)/.exec(body);
      if (!alpha || Number(alpha[1]) >= 1 || Number(alpha[1]) === 0) continue;
      const token = /(?:^|;|\s)color:\s*var\((--text-[a-z-]+)\)/.exec(body);
      if (!token) continue;
      found.push({ where: `${name} ${match[1].trim()}`, token: token[1], alpha: Number(alpha[1]) });
    }
  }
  return found;
}

function flatSurfaces(isDark: boolean): { vars: Record<string, string>; flat: Record<string, RGB> } {
  const { vars } = surfaces(isDark);
  const page = parse(vars["--page-bg"]);
  return {
    vars,
    flat: {
      page,
      card: composite(vars["--surface"], page),
      raised: composite(vars["--surface-raised"], page),
      sunken: composite(vars["--surface-sunken"], page),
      // Menus and modals paint on this opaque panel, not on the page. The
      // binary dialog's help and note lines and the model menu's loading row
      // are all --text-faint on exactly this bed.
      popover: parse(vars["--popover-bg"]),
      // The dialog's input well, over that panel.
      popoverInput: composite(vars["--input-bg"], parse(vars["--popover-bg"]))
    }
  };
}

describe("chrome text contrast", () => {
  test("no rule dims an already-muted text token below AA", async () => {
    const rules = await attenuatedTextRules();
    const failures: string[] = [];
    for (const isDark of [true, false]) {
      const label = isDark ? "dark" : "light";
      const { vars, flat } = flatSurfaces(isDark);
      for (const rule of rules) {
        const color = vars[rule.token];
        if (!color) continue;
        for (const [name, bed] of Object.entries(flat)) {
          const fg = composite(color, bed);
          const composited = [0, 1, 2].map(
            (i) => fg[i] * rule.alpha + bed[i] * (1 - rule.alpha)
          ) as RGB;
          const value = ratio(composited, bed);
          if (value < AA_SMALL) {
            failures.push(`${label} ${rule.where} on ${name}=${value.toFixed(2)}`);
          }
        }
      }
    }
    expect(failures).toEqual([]);
  });

  test("the secondary text tiers clear AA unattenuated on every flat surface", async () => {
    const failures: string[] = [];
    for (const isDark of [true, false]) {
      const label = isDark ? "dark" : "light";
      const { vars, flat } = flatSurfaces(isDark);
      for (const token of ["--text-faint", "--text-muted", "--text-soft"]) {
        for (const [name, bed] of Object.entries(flat)) {
          const value = ratio(composite(vars[token], bed), bed);
          if (value < AA_SMALL) failures.push(`${label} ${token} on ${name}=${value.toFixed(2)}`);
        }
      }
    }
    expect(failures).toEqual([]);
  });

  test("the two rules that failed the browser sweep carry no opacity at all", async () => {
    // Composited: 2.95:1 (light) / 3.93:1 (dark) for the compaction token count,
    // and 3.53:1 for the api_retry countdown on its amber bed. Both were the
    // only real numbers in their row.
    const transcript = await sheet("transcript.css");
    const dock = await sheet("dock.css");
    expect(/\.divider-sub\s*\{[^}]*\}/.exec(transcript)![0]).not.toMatch(/opacity/);
    expect(/\.banner-detail\s*\{[^}]*\}/.exec(dock)![0]).not.toMatch(/opacity/);
    // 10.5px was also under the 12px meta size the visual bar specifies.
    expect(/\.banner-detail\s*\{[^}]*\}/.exec(dock)![0]).toMatch(/font-size:\s*11\.5px/);
  });
});

/**
 * Dialogs paint on an OPAQUE panel (--popover-bg), not on the page, and their
 * status tones sit on their own tints over that panel. A validation error the
 * user cannot read is the same as no error at all, and that copy is the only
 * thing standing between a mistyped path and silent failure.
 */
describe("dialog status tones contrast", () => {
  for (const isDark of [true, false]) {
    const label = isDark ? "dark" : "light";
    const { vars } = surfaces(isDark);
    const panel = parse(vars["--popover-bg"]);

    test(`the binary validation error clears AA on its tint (${label})`, () => {
      const bed = composite(vars["--danger-soft"], panel);
      expect(ratio(composite(vars["--danger"], bed), bed)).toBeGreaterThanOrEqual(AA_SMALL);
    });

    test(`the degraded-rewind warning clears AA on the panel (${label})`, () => {
      expect(ratio(composite(vars["--warning"], panel), panel)).toBeGreaterThanOrEqual(AA_SMALL);
    });

    test(`the quoted message clears AA on its claude tint (${label})`, () => {
      const bed = composite(vars["--claude-faint"], panel);
      expect(ratio(composite(vars["--text"], bed), bed)).toBeGreaterThanOrEqual(AA_SMALL);
      // The file-count stat beside the checkbox is the faintest tier here.
      const well = composite(vars["--input-bg"], panel);
      expect(ratio(composite(vars["--text-faint"], well), well)).toBeGreaterThanOrEqual(AA_SMALL);
    });
  }
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

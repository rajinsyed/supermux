import { describe, expect, test } from "bun:test";

/**
 * Round-5 rebuild contracts.
 *
 * Every assertion here is a bug that actually shipped or was caught in the
 * browser during this pass, not a restatement of the CSS.
 */

async function css(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

/**
 * The sheet with its comments stripped.
 *
 * These sheets carry long prose explaining WHY a rule is what it is, and that
 * prose quotes selectors and keyframe names — so a scan of the raw text reports
 * a rule that is only being discussed. Needed for any assertion about what the
 * sheet DECLARES rather than what it says.
 */
async function rules(name: string): Promise<string> {
  return (await css(name)).replace(/\/\*[\s\S]*?\*\//g, "");
}

async function source(path: string): Promise<string> {
  return Bun.file(new URL(`../src/${path}`, import.meta.url).pathname).text();
}

const SHEETS = [
  "base.css",
  "menu.css",
  "rail.css",
  "cards.css",
  "content.css",
  "dock.css",
  "layout.css",
  "modal.css",
  "tasks.css",
  "tools.css",
  "transcript.css",
  "workflow.css",
  "agents.css"
];

describe("the shimmer is not overridden by another sheet's keyframe", () => {
  test("no @keyframes name is declared in two sheets", async () => {
    // This shipped broken: the working label and the thinking label both used
    // `@keyframes shimmer-sweep`, with different travel ranges tuned to
    // different background-sizes. Keyframe names are GLOBAL and the last
    // declaration wins, so the thinking label's 200% → -200% range silently
    // drove the working label's 260% background — pushing the gradient off the
    // element, and with `color: transparent` half of "Working for 6s"
    // disappeared on every cycle. A name collision here is invisible in every
    // unit test and obvious only on screen.
    const seen = new Map<string, string[]>();
    for (const name of SHEETS) {
      const sheet = await rules(name);
      for (const match of sheet.matchAll(/@keyframes\s+([A-Za-z0-9_-]+)/g)) {
        seen.set(match[1], (seen.get(match[1]) ?? []).concat(name));
      }
    }
    const duplicated = [...seen.entries()]
      .filter(([, sheets]) => sheets.length > 1)
      .map(([name, sheets]) => `${name} in ${sheets.join(" + ")}`);
    expect(duplicated).toEqual([]);
  });

  test("every animation names a keyframe that exists", async () => {
    // The browser's running dots referenced `dock-pulse`, which no sheet ever
    // declared — so the one mark that says "this agent is working" was
    // perfectly static, in both themes, for every run.
    const declared = new Set<string>();
    const used = new Map<string, string>();
    for (const name of SHEETS) {
      const sheet = await rules(name);
      for (const match of sheet.matchAll(/@keyframes\s+([A-Za-z0-9_-]+)/g)) {
        declared.add(match[1]);
      }
      for (const match of sheet.matchAll(/animation:\s*([A-Za-z][A-Za-z0-9_-]*)/g)) {
        used.set(match[1], name);
      }
    }
    const missing = [...used.entries()]
      .filter(([keyframe]) => !declared.has(keyframe))
      .map(([keyframe, sheet]) => `${keyframe} (${sheet})`);
    expect(missing).toEqual([]);
  });

  test("the sweep never slides the gradient off the glyphs it paints", async () => {
    // With `background-size: 260%`, a percentage position resolves against a
    // NEGATIVE span (element − image), so every value inside [0, 100] still
    // covers the element edge to edge and every value outside it exposes an
    // unpainted strip. `background-clip: text` + `color: transparent` means an
    // unpainted strip is INVISIBLE TEXT, not a dimmer sheen.
    const sheet = await css("base.css");
    const frames = /@keyframes sheen-sweep\s*\{([\s\S]*?)\n\}/.exec(sheet);
    expect(frames).not.toBeNull();
    const positions = [...frames![1].matchAll(/background-position:\s*(-?[\d.]+)%/g)].map((m) =>
      Number(m[1])
    );
    expect(positions.length).toBeGreaterThanOrEqual(2);
    for (const position of positions) {
      expect(position).toBeGreaterThanOrEqual(0);
      expect(position).toBeLessThanOrEqual(100);
    }
  });

  test("with motion off the shimmering text is painted, not frozen transparent", async () => {
    // `color: transparent` plus a stopped animation is an invisible label. The
    // reduced-motion branch has to restore a real ink colour everywhere the
    // sweep sets `-webkit-text-fill-color: transparent`.
    for (const name of ["base.css", "cards.css", "agents.css"]) {
      const sheet = await css(name);
      if (!sheet.includes("-webkit-text-fill-color: transparent")) continue;
      const reduced = sheet.slice(sheet.indexOf("@media (prefers-reduced-motion: reduce)"));
      expect(reduced).toContain("-webkit-text-fill-color: var(--shimmer-sheen)");
    }
  });
});

describe("the three-dot loaders are gone", () => {
  test("nothing renders a stack of pulsing dots any more", async () => {
    const spinner = await source("ui/primitives/Spinner.tsx");
    // One sliver per mark. Three or four bare `<i />` children is the old
    // dot constellation; the shimmer is a single element.
    expect(spinner.match(/<i /g)?.length).toBe(2);
    expect(spinner).toContain("sheen-bar");
    // The exported names are the contract other files consume.
    for (const name of ["Spinner", "WorkingDots", "WorkingGlyph"]) {
      expect(spinner).toContain(`export function ${name}(`);
    }
  });

  test("the working label sweeps with its mark, not beside it", async () => {
    // The whole reason the dots could go: the animation lands on the words that
    // already say what is happening.
    const cards = await css("cards.css");
    expect(cards).toContain(".turn-live .working-dots + .turn-live-label");
    expect(cards).toContain("background-clip: text");
    const agents = await css("agents.css");
    expect(agents).toContain(".dock-glyph + .dock-label");
  });
});

describe("the composer's input row shares one centreline", () => {
  test("every control on the row declares the row's own line height", async () => {
    // The previous build asserted this in a comment and did not have it: it
    // bottom-aligned the row and called a 4 + 18 + 4 text box "26px", against
    // 26px BUTTONS whose glyphs centre in their own boxes. `flex-end` aligns the
    // bottom of a text box, and the bottom of a text box is not its baseline —
    // so the placeholder, the + control, the model chip and send all sat on
    // four different lines.
    const sheet = await css("dock.css");
    const shell = /\.composer-shell\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(shell).toMatch(/--composer-line:\s*(\d+)px/);
    expect(shell).toMatch(/align-items:\s*center/);

    const line = Number(/--composer-line:\s*(\d+)px/.exec(shell)![1]);
    for (const selector of [
      ".composer-attach",
      ".composer-actions .btn-send,\n.composer-actions .btn-stop",
      ".composer-model-trigger"
    ]) {
      const rule = new RegExp(`${selector.replace(/[.\\+*?[^\]$(){}=!<>|:\-#]/g, "\\$&")}\\s*\\{([^}]*)\\}`).exec(
        sheet
      );
      expect(rule).not.toBeNull();
      expect(rule![1]).toContain("var(--composer-line)");
    }

    // The textarea's own box has to SUM to the same line, with symmetric
    // padding, or the single line of text is centred against nothing.
    const input = /\.composer-input\s*\{([^}]*)\}/.exec(sheet)![1];
    const padding = Number(/padding:\s*(\d+)px/.exec(input)![1]);
    const lineHeight = Number(/line-height:\s*(\d+)px/.exec(input)![1]);
    expect(padding * 2 + lineHeight).toBe(line);
  });

  test("a grown draft drops the controls to the last line instead", async () => {
    // The case `flex-end` existed for, handled where it belongs rather than
    // applied to the single-line state as well.
    const sheet = await css("dock.css");
    expect(sheet).toMatch(
      /\.composer-shell:has\(\.composer-input\.is-multiline\)\s*\{[^}]*align-items:\s*flex-end/
    );
  });

  test("the multi-line threshold and the CSS line agree", async () => {
    // A drift here puts the pill into its multi-line alignment for an ordinary
    // one-line draft — the exact state the round-5 screenshot caught.
    const sheet = await css("dock.css");
    const line = Number(/--composer-line:\s*(\d+)px/.exec(sheet)![1]);
    const composer = await source("ui/composer/Composer.tsx");
    const threshold = Number(/const SINGLE_LINE_HEIGHT = (\d+)/.exec(composer)![1]);
    expect(threshold).toBe(line);
  });
});

describe("one menu kit, worn by every floating surface", () => {
  test("no surface re-declares the popover material", async () => {
    // Round 4's five popovers each rebuilt the panel: three radii, three
    // paddings, two z-indexes, one shadow between them. Geometry (width,
    // max-height) is a surface's own business; the MATERIAL is the kit's.
    const owned = ["dock.css", "layout.css", "transcript.css", "workflow.css"];
    const offenders: string[] = [];
    for (const name of owned) {
      const sheet = await rules(name);
      for (const match of sheet.matchAll(/\n(\.pop-[a-z-]+)\s*\{([^}]*)\}/g)) {
        for (const property of ["border:", "box-shadow:", "background:", "position:"]) {
          if (match[2].includes(property)) offenders.push(`${name} ${match[1]} ${property}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });

  test("the kit's surface carries the layered popover shadow", async () => {
    // A menu is the one surface with nothing behind it but readable text; a
    // hairline alone cannot say "this is in front", which is why round 4's
    // menus read as rectangles pasted onto the transcript.
    const sheet = await css("menu.css");
    expect(/\.ui-pop\s*\{([^}]*)\}/.exec(sheet)![1]).toContain("var(--shadow-popover)");
  });

  test("every floating surface in the pane is built from the kit", async () => {
    // The check that keeps this from decaying: a component that hand-rolls a
    // `position: absolute` panel is a sixth dialect starting up again.
    const files = ["ui/header/Header.tsx", "ui/header/ContextRing.tsx", "ui/composer/Composer.tsx", "ui/composer/ModelMenu.tsx"];
    for (const path of files) {
      const text = await source(path);
      expect(text).toMatch(/from "\.\.\/primitives\/Popover"/);
    }
  });

  test("the retired menu classes are not left behind in a sheet", async () => {
    // Dead rules keep winning at equal specificity long after the markup that
    // needed them is gone.
    const layout = await rules("layout.css");
    for (const dead of [".menu-pop", ".menu-item-detail", ".sessions-search", ".ctx-pop {"]) {
      expect(layout).not.toContain(dead);
    }
    const dock = await rules("dock.css");
    for (const dead of [".popover-item", ".model-efforts", ".model-tune"]) {
      expect(dock).not.toContain(dead);
    }
  });
});

describe("the message rail is a map, not a second scrollbar", () => {
  test("it sits at the LEFT edge, vertically centred, and is capped", async () => {
    // It ran full-height down the right edge, directly under the scrollbar —
    // two position indicators a pixel apart, disagreeing about what they
    // measure, since the rail counts turns and the scrollbar counts pixels.
    const sheet = await css("rail.css");
    const rail = /\.msg-rail\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(rail).toMatch(/left:\s*0/);
    expect(rail).not.toMatch(/(?:^|\s)right:/);
    expect(rail).toMatch(/top:\s*50%/);
    expect(rail).toMatch(/transform:\s*translateY\(-50%\)/);
    expect(rail).toMatch(/max-height:\s*min\(/);
  });

  test("the old right-edge rail cannot render alongside it", async () => {
    // `TranscriptList` still mounts the old `<Timeline>` (it lives in a
    // directory this change does not own), so both would draw.
    const sheet = await css("rail.css");
    expect(/\.timeline\s*\{([^}]*)\}/.exec(sheet)![1]).toMatch(/display:\s*none/);
  });

  test("exactly one tick is active, and it is the pane's centre", async () => {
    // The old rail lit every turn overlapping the viewport, so a pane showing
    // four short turns brightened four ticks and said nothing about where the
    // reader was.
    const rail = await source("ui/primitives/MessageRail.tsx");
    expect(rail).toContain("scroller.clientHeight / 2");
    expect(rail).toMatch(/bestDistance/);
    // No React state on the scroll path: the active mark is written straight to
    // the dataset, so a scroll never re-renders the transcript. A `setState`
    // here would make every scroll event a render of the whole turn list.
    const update = rail.slice(rail.indexOf("const update = ()"), rail.indexOf("update();"));
    expect(update).not.toMatch(/\bset(?:Hover|State)\b|\bsetHover\(/);
    expect(update).toContain("dataset.active");
  });

  test("the ticks stay out of the tab order", async () => {
    // Twenty-four invisible stops ahead of the composer is worse than no
    // keyboard affordance; the turns are reachable by scrolling and the
    // transcript is a labelled log region.
    const rail = await source("ui/primitives/MessageRail.tsx");
    expect(rail).toContain("tabIndex={-1}");
  });
});

describe("dark surfaces are dark and translucent, not washed grey", () => {
  test("no dark surface token is a white veil", async () => {
    // A white veil over near-black is the one operation that turns black into
    // grey, and stacked three deep it produced the slab the round-5 report
    // rejected. Interaction highlights stay white by design — a black hover on
    // near-black is invisible — so only the SURFACES are asserted.
    const { defaultDarkTheme, themeVariables } = await import("../src/ui/theme");
    const vars = themeVariables(defaultDarkTheme);
    for (const token of ["--surface", "--surface-raised", "--surface-sunken", "--panel", "--input-bg"]) {
      const value = vars[token];
      const rgb = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/.exec(value)!;
      const brightest = Math.max(Number(rgb[1]), Number(rgb[2]), Number(rgb[3]));
      expect(`${token}=${value}`).toBe(`${token}=${value}`);
      expect(brightest).toBeLessThan(40);
    }
  });

  test("they are translucent, so the native window shows through", async () => {
    // The WKWebView is transparent over the app's own window; an opaque surface
    // has nothing to show through it, which is half of what "washed" meant.
    const { defaultDarkTheme, themeVariables } = await import("../src/ui/theme");
    const vars = themeVariables(defaultDarkTheme);
    for (const token of ["--surface", "--surface-raised", "--panel", "--popover-bg", "--input-bg"]) {
      const alpha = /rgba\([^)]*[,\s/]\s*([\d.]+)\s*\)/.exec(vars[token]);
      expect(`${token} alpha`).toBe(`${token} alpha`);
      expect(alpha).not.toBeNull();
      expect(Number(alpha![1])).toBeLessThan(1);
    }
  });

  test("a popover stays near-opaque, so text cannot bleed through it", async () => {
    // The one surface that must NOT be see-through: it floats over readable
    // content, and a translucent menu lets the transcript print through its
    // rows.
    const { defaultDarkTheme, defaultLightTheme, themeVariables } = await import("../src/ui/theme");
    for (const theme of [defaultDarkTheme, defaultLightTheme]) {
      const value = themeVariables(theme)["--popover-bg"];
      const alpha = Number(/rgba\([^)]*[,\s/]\s*([\d.]+)\s*\)/.exec(value)![1]);
      expect(alpha).toBeGreaterThanOrEqual(0.94);
    }
  });
});

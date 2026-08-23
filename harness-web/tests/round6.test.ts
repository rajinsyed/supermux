import { describe, expect, test } from "bun:test";

/**
 * Round-6 kit contracts.
 *
 * The report for this pass was "i told you to redesign the pickers and menus
 * (all) and they still look same and ugly. no animations or good taste
 * whatsoever", and every assertion here pins one half of the answer to it. The
 * point of writing them as tests rather than as comments is that all three
 * defects were the kind that decay silently: a menu built outside the kit, an
 * animation with no exit half, a duration that drifts away from the timer that
 * unmounts the panel it animates.
 */

async function css(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

/** The sheet with its comments stripped, so prose quoting a selector is not a rule. */
async function rules(name: string): Promise<string> {
  return (await css(name)).replace(/\/\*[\s\S]*?\*\//g, "");
}

async function source(path: string): Promise<string> {
  return Bun.file(new URL(`../src/${path}`, import.meta.url).pathname).text();
}

function ruleFor(sheet: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(
    `(?:^|\\n)(?:[^{}]*,\\s*)?${escaped}\\s*(?:,[^{}]*)?\\{([^}]*)\\}`
  ).exec(sheet);
  if (!match) throw new Error(`no rule for ${selector}`);
  return match[1];
}

describe("every floating surface animates in AND out", () => {
  test("the kit declares both halves, not just an entrance", async () => {
    // Round 5 had `animation: ui-pop-in 110ms` and nothing else, so every menu
    // in the pane spent 110ms arriving and zero frames leaving. An interface
    // that appears smoothly and disappears instantly reads as a display:none
    // toggle wearing a transition, which is what "no animations" named.
    const sheet = await rules("menu.css");
    expect(sheet).toContain("@keyframes ui-pop-in");
    expect(sheet).toContain("@keyframes ui-pop-out");
    expect(ruleFor(sheet, ".ui-pop.is-closing")).toContain("ui-pop-out");
  });

  test("both halves move only transform and opacity", async () => {
    // A keyframe that animates a layout property reflows the bar behind the
    // panel on every frame of the open.
    const sheet = await css("menu.css");
    const allowed = new Set(["opacity", "transform"]);
    for (const name of ["ui-pop-in", "ui-pop-out", "modal-in", "modal-scrim-in", "card-in"]) {
      const sheets = [await css("menu.css"), await css("modal.css"), await css("cards.css")];
      const body = sheets
        .map((text) => new RegExp(`@keyframes ${name}\\s*\\{([\\s\\S]*?)\\n\\}`).exec(text)?.[1])
        .find((found) => found !== undefined);
      expect(`${name} declared`).toBe(`${name} declared`);
      expect(body).toBeDefined();
      const properties = [...body!.matchAll(/\n\s+([a-z-]+):/g)].map((match) => match[1]);
      expect(properties.length).toBeGreaterThan(0);
      for (const property of properties) {
        expect(`${name}:${property}`).toBe(`${name}:${allowed.has(property) ? property : "LAYOUT"}`);
      }
    }
    expect(sheet).toContain("--ease-out");
  });

  test("the exit hold and the CSS duration are the same number", async () => {
    // The component keeps a closing panel mounted for `POP_OUT_MS` and the
    // sheet animates it for `--pop-out`. A drift unmounts the panel
    // mid-animation, which looks exactly like the instant disappearance this
    // replaces — and no unit test would see it.
    const motion = await source("ui/motion.ts");
    const sheet = await rules("menu.css");
    const inMs = Number(/POP_IN_MS = (\d+)/.exec(motion)![1]);
    const outMs = Number(/POP_OUT_MS = (\d+)/.exec(motion)![1]);
    expect(Number(/--pop-in:\s*(\d+)ms/.exec(sheet)![1])).toBe(inMs);
    expect(Number(/--pop-out:\s*(\d+)ms/.exec(sheet)![1])).toBe(outMs);
    // An exit that outlasts its entrance reads as lag rather than as polish.
    expect(outMs).toBeLessThan(inMs);
    // The brief's window: fast enough not to be waited on, slow enough to see.
    expect(inMs).toBeGreaterThanOrEqual(120);
    expect(inMs).toBeLessThanOrEqual(160);
  });

  test("the panel grows from the trigger's own corner, not from its centre", async () => {
    // `transform-origin: center` makes a panel materialise OVER its trigger;
    // the corner is what makes it look like it came OUT of it. Both axes are
    // set, because a bottom-bar menu pinned right grows from bottom-right.
    const sheet = await rules("menu.css");
    expect(ruleFor(sheet, ".ui-pop")).toMatch(/transform-origin:\s*var\(--pop-origin-y/);
    expect(ruleFor(sheet, ".ui-pop.is-top")).toContain("--pop-origin-y: bottom");
    expect(ruleFor(sheet, ".ui-pop.is-bottom")).toContain("--pop-origin-y: top");
    expect(ruleFor(sheet, ".ui-pop.is-end")).toContain("--pop-origin-x: right");
    expect(ruleFor(sheet, ".ui-pop.is-start")).toContain("--pop-origin-x: left");
    // The travel follows the side, or the panel slides the wrong way out of it.
    expect(ruleFor(sheet, ".ui-pop.is-bottom")).toMatch(/--pop-rise:\s*-\d/);
  });

  test("with motion off a surface is simply there", async () => {
    // base.css collapses every duration to 0.001ms, which leaves the OPENING
    // frame (opacity 0, scale 0.94) on screen for one tick. Naming the end
    // state is what makes the appearance genuinely instant.
    for (const name of ["menu.css", "modal.css", "cards.css"]) {
      const sheet = await css(name);
      const reduced = sheet.slice(sheet.indexOf("@media (prefers-reduced-motion: reduce)"));
      expect(`${name} has a reduced-motion branch`).toBe(`${name} has a reduced-motion branch`);
      expect(reduced.length).toBeGreaterThan(0);
      expect(reduced).toContain("animation-name: none");
      expect(reduced).toContain("opacity: 1");
      expect(reduced).toContain("transform: none");
    }
  });

  test("the closing panel is out of the tree and out of the tab order", async () => {
    // It survives ~100ms after being answered. For that time a screen reader
    // must not read it and Tab must not land in it.
    const popover = await source("ui/primitives/Popover.tsx");
    expect(popover).toContain('aria-hidden={closing ? true : undefined}');
    expect(popover).toContain("inert={closing ? true : undefined}");
    expect(await rules("menu.css")).toMatch(/\.ui-pop\.is-closing\s*\{[^}]*pointer-events:\s*none/);
  });

  test("escape hands focus back immediately, not after the exit", async () => {
    // A control that is still visible but no longer focusable is exactly where
    // a keyboard user gets stranded, so the focus handover happens BEFORE the
    // timer that unmounts the panel rather than inside it.
    const popover = await source("ui/primitives/Popover.tsx");
    const close = popover.slice(popover.indexOf("const close = useCallback"));
    const handover = close.indexOf("triggerRef.current?.focus()");
    const timer = close.indexOf("window.setTimeout");
    expect(handover).toBeGreaterThan(-1);
    expect(timer).toBeGreaterThan(-1);
    expect(handover).toBeLessThan(timer);
  });
});

describe("the kit's material is layered, not a flat rectangle", () => {
  test("the panel is translucent glass over a saturating blur", async () => {
    // The round-5 request the round-6 pass keeps: darker translucent surfaces
    // so the native window's vibrancy genuinely reads through the chrome.
    const rule = ruleFor(await rules("menu.css"), ".ui-pop");
    expect(rule).toContain("var(--popover-bg)");
    expect(rule).toContain("backdrop-filter: var(--glass-blur)");
    expect(rule).toContain("1px solid var(--border)");
    expect(rule).toContain("var(--shadow-popover)");
  });

  test("the glass highlight is a hairline, never an inset shadow", async () => {
    // Composited inside the panel's own 1px border, `inset 0 1px 0` renders the
    // top stroke visibly heavier than the other three — the defect the composer
    // pill already documents in dock.css and tests/styles.test.ts guards there.
    for (const [name, selector] of [
      ["menu.css", ".ui-pop::before"],
      ["modal.css", ".modal::before"]
    ] as const) {
      const rule = ruleFor(await rules(name), selector);
      expect(rule).toContain("var(--pop-sheen)");
      expect(rule).toMatch(/height:\s*1px/);
      expect(rule).toContain("pointer-events: none");
    }
    // And the panel itself never grows one back.
    expect(ruleFor(await rules("menu.css"), ".ui-pop")).not.toContain("inset");
  });

  test("the four type tiers are declared once and are genuinely distinct", async () => {
    // A section title, a row label, a consequence line and a trailing fact at
    // 11.5–13px in three greys is one undifferentiated list, which is what
    // "no typographic hierarchy" named.
    const sheet = await rules("menu.css");
    const root = ruleFor(sheet, ":root");
    const size = (token: string) =>
      Number(new RegExp(`${token}:\\s*([\\d.]+)px`).exec(root)![1]);
    const label = size("--menu-label-size");
    const detail = size("--menu-detail-size");
    const meta = size("--menu-meta-size");
    const title = size("--menu-title-size");
    expect(label).toBeGreaterThan(detail);
    expect(detail).toBeGreaterThan(meta);
    expect(meta).toBeGreaterThan(title);
    // The label is the only tier at full weight and full ink; the title is the
    // only one that is uppercase.
    expect(ruleFor(sheet, ".ui-menu-label-text")).toMatch(/font-weight:\s*500/);
    expect(ruleFor(sheet, ".ui-menu-label")).toContain("text-transform: uppercase");
    expect(ruleFor(sheet, ".ui-menu-detail")).not.toContain("text-transform");
  });

  test("a row answers the pointer instantly and the press is a gesture", async () => {
    // A hover eased over 160ms feels laggy; the PRESS is the thing that should
    // be eased, because it is a gesture rather than a state.
    const sheet = await rules("menu.css");
    const item = ruleFor(sheet, ".ui-menu-item");
    expect(item).toMatch(/transition:[^;]*background 90ms linear/);
    expect(ruleFor(sheet, ".ui-menu-item:active:not(:disabled)")).toMatch(/transform:\s*scale\(/);
    expect(ruleFor(sheet, ".menu-trigger:active")).toMatch(/transform:\s*scale\(/);
  });

  test("the chosen row keeps its mark when the pointer leaves", async () => {
    // It is what the panel is REPORTING, not something the cursor is doing. In
    // round 5 `.is-active` set only a text colour, so a checked row and an
    // unchecked one were the same object with a glyph.
    const sheet = await rules("menu.css");
    const active = ruleFor(sheet, ".ui-menu-item.is-active");
    expect(active).toContain("var(--claude-faint)");
    expect(ruleFor(sheet, ".ui-menu-check")).toContain("var(--claude)");
  });
});

describe("every popover in the pane is the kit's", () => {
  test("no component hand-rolls a floating panel", async () => {
    // The check that keeps the five-dialect problem from starting again: a
    // `position: absolute` panel built in a component is a sixth one.
    const files = [
      "ui/header/Header.tsx",
      "ui/header/ContextRing.tsx",
      "ui/composer/Composer.tsx",
      "ui/composer/ModelMenu.tsx"
    ];
    for (const path of files) {
      const text = await source(path);
      expect(`${path} uses the kit`).toBe(`${path} uses the kit`);
      expect(text).toMatch(/from "\.\.\/primitives\/Popover"/);
    }
  });

  test("no sheet outside the kit re-declares the popover material", async () => {
    // Geometry (width, max-height) is a surface's own business. Material is the
    // kit's, or the six panels drift apart again the moment one is touched.
    const owned = ["dock.css", "layout.css", "transcript.css", "workflow.css", "cards.css"];
    const offenders: string[] = [];
    for (const name of owned) {
      const sheet = await rules(name);
      for (const match of sheet.matchAll(/\n(\.pop-[a-z-]+)\s*\{([^}]*)\}/g)) {
        for (const property of ["border:", "box-shadow:", "background:", "position:", "animation"]) {
          if (match[2].includes(property)) offenders.push(`${name} ${match[1]} ${property}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });

  test("the slash menu's row is the kit's two-line row, not a one-line sentence", async () => {
    // Named twice in the round-6 report. `name · hint · description` on one
    // baseline meant a long description pushed the command's own meaning off
    // the right edge and every row was a different length of grey.
    const list = await source("ui/primitives/MenuList.tsx");
    expect(list).toContain("ui-cmd-line");
    const sheet = await rules("menu.css");
    expect(ruleFor(sheet, ".ui-cmd-item")).toMatch(/flex-direction:\s*column/);
    expect(ruleFor(sheet, ".ui-cmd-line")).toMatch(/align-items:\s*baseline/);
    // The keyboard mark survives the pointer being elsewhere: ⏎ acts on the
    // MARKED row, not the hovered one.
    expect(ruleFor(sheet, ".ui-cmd-item.is-active")).toContain("var(--claude-faint)");
    expect(sheet).toContain(".ui-cmd-item.is-active::before");
    // And the composer still mounts it on the kit's surface.
    const composer = await source("ui/composer/Composer.tsx");
    expect(composer).toContain("<PopoverSurface");
    expect(composer).toContain("<CommandList");
  });
});

describe("the dialogs speak the popover's language", () => {
  test("a modal arrives on the same curve and duration as a menu", async () => {
    const sheet = await rules("modal.css");
    expect(ruleFor(sheet, ".modal")).toMatch(/animation:\s*modal-in var\(--pop-in\) var\(--ease-out\)/);
    expect(ruleFor(sheet, ".modal-scrim")).toContain("var(--pop-in)");
  });

  test("it wears the popover panel's own material", async () => {
    const rule = ruleFor(await rules("modal.css"), ".modal");
    expect(rule).toContain("var(--popover-bg)");
    expect(rule).toContain("backdrop-filter: var(--glass-blur)");
  });

  test("the rewind dialog is compact rather than a 460px form", async () => {
    const dialog = await source("ui/transcript/RewindDialog.tsx");
    expect(dialog).toContain('size="compact"');
    const compact = Number(/\.modal\.is-compact\s*\{[^}]*width:\s*min\((\d+)px/.exec(
      await rules("modal.css")
    )![1]);
    const base = Number(/\n\.modal\s*\{[^}]*width:\s*min\((\d+)px/.exec(await rules("modal.css"))![1]);
    expect(compact).toBeLessThan(base);
  });

  test("it states the two effects a rewind has rather than describing them", async () => {
    // Round 5 was a quote, a sentence, a well and a checkbox — four unrelated
    // blocks in which the reader had to work out that a rewind does two
    // separable things. It is a list of those two things now.
    const dialog = await source("ui/transcript/RewindDialog.tsx");
    expect(dialog).toContain("rewind.conversationTitle");
    expect(dialog).toContain("rewind.restoreFiles");
    expect(dialog).toContain("rewind.always");
    const sheet = await rules("modal.css");
    // The always-on half is NOT drawn as a checkbox: a control that cannot be
    // unchecked lies about being one.
    expect(ruleFor(sheet, ".rewind-effect-mark")).toContain("var(--claude)");
    // The armable half takes the pane's one selection grammar.
    expect(ruleFor(sheet, ".rewind-check.is-on")).toContain("var(--claude-border)");
    expect(ruleFor(sheet, ".rewind-check.is-on")).toContain("var(--claude-faint)");
  });

  test("what crosses the bridge is untouched", async () => {
    // The redesign is a reskin: one boolean, still `restoreFiles && !degraded`.
    const dialog = await source("ui/transcript/RewindDialog.tsx");
    expect(dialog).toContain("const armed = restoreFiles && !degraded;");
    expect(dialog).toContain("onClick={() => onConfirm(armed)}");
  });
});

describe("the question card is an approval card, not a wall", () => {
  test("only the live question is rendered", async () => {
    // The report's own words: "Not answered yet" placeholders held a block of
    // card open for every question the user had not reached.
    const card = await source("ui/permission/QuestionCard.tsx");
    expect(card).not.toContain("question.unanswered");
    expect(card).not.toContain("answer-chip");
    expect(card).not.toContain("question-list");
    // One question, addressed by index, with a stepper for the rest.
    expect(card).toContain('data-index={active}');
    expect(card).toContain("q-step-dot");
  });

  test("an option row is quiet until it is chosen", async () => {
    // `border: 1px solid var(--border)` on every row made four options read as
    // four cards, and the number keys sat in bordered squares on top of that.
    const sheet = await rules("cards.css");
    expect(ruleFor(sheet, ".option")).toContain("border: 1px solid transparent");
    const on = ruleFor(sheet, ".option.is-on");
    expect(on).toContain("var(--claude-border)");
    expect(on).toContain("var(--claude-faint)");
    // The number hint is a bare glyph now, not a box.
    const key = ruleFor(sheet, ".option-key");
    expect(key).not.toContain("border");
    expect(key).not.toMatch(/width:/);
  });

  test("the affordance says whether more than one may be picked", async () => {
    const sheet = await rules("cards.css");
    expect(ruleFor(sheet, ".option-mark")).toContain("var(--r-pill)");
    expect(ruleFor(sheet, ".option-mark.is-multi")).toMatch(/border-radius:\s*4px/);
  });

  test("no dimmed text rule reintroduces the opacity trap", async () => {
    // Both of this card's quiet tiers were written with `opacity` first and
    // composited under AA (2.0:1 and 4.2:1); tests/contrast.test.ts caught them.
    // They are TONE now, and must stay that way.
    const sheet = await rules("cards.css");
    for (const selector of [".option-key", ".q-step-arrow:disabled"]) {
      expect(`${selector} carries no opacity`).toBe(`${selector} carries no opacity`);
      expect(ruleFor(sheet, selector)).not.toMatch(/(?<!-)opacity:/);
    }
  });

  test("the three decision cards still share one shell", async () => {
    // The reskin is applied through the shared selector group, so permission
    // and plan get it without their logic being touched.
    const sheet = await rules("cards.css");
    const shell = ruleFor(sheet, ".question-card");
    expect(shell).toContain("var(--shadow-popover)");
    expect(shell).toContain("animation: card-in");
    for (const card of [".permission-card", ".plan-card"]) {
      expect(`${card} shares the shell`).toBe(`${card} shares the shell`);
      expect(sheet).toContain(card);
      expect(ruleFor(sheet, card)).toBe(shell);
    }
  });

  test("what the card submits is unchanged", async () => {
    // A reskin, not a protocol change: the same merged answer map, the same
    // deny message on Skip.
    const card = await source("ui/permission/QuestionCard.tsx");
    expect(card).toContain('behavior: "allow"');
    expect(card).toContain("updatedInput: { questions: request.input.questions, answers: payload }");
    expect(card).toContain('behavior: "deny", message: copy("supermux.harness.question.dismissed")');
  });
});

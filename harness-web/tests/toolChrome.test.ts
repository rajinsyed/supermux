import { describe, expect, test } from "bun:test";

async function css(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

/** Same matcher styles.test.ts uses: the declaration block a selector is in. */
function ruleFor(sheet: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(
    `(?:^|\\n)(?:[^{}]*,\\s*)?${escaped}\\s*(?:,[^{}]*)?\\{([^}]*)\\}`
  ).exec(sheet);
  if (!match) throw new Error(`no rule for ${selector}`);
  return match[1];
}

describe("the user message is a right-aligned chat bubble", () => {
  test("it sizes to content, pushed right, with a sane cap", async () => {
    const sheet = await css("transcript.css");
    const bubble = ruleFor(sheet, ".user-msg");
    // Cursor/iMessage grammar: auto left margin pushes the bubble to the
    // column's right edge; fit-content keeps a short prompt short.
    expect(bubble).toMatch(/margin:[^;]*auto/);
    expect(bubble).toMatch(/width:\s*fit-content/);
    const cap = Number(/max-width:\s*(\d+)%/.exec(bubble)?.[1]);
    expect(cap).toBeGreaterThanOrEqual(70);
    expect(cap).toBeLessThanOrEqual(90);
  });
});

describe("a failed tool is an accent, not a red-washed frame", () => {
  test("the open error card carries a left status ink, no tinted body", async () => {
    const sheet = await css("tools.css");
    const open = ruleFor(sheet, ".tool-card.is-error.is-open");
    // The failure signal is the inset edge; a full danger border or a
    // danger-soft body wash painted the whole card as an alarm for what is
    // usually one line of stderr.
    expect(open).toMatch(/inset[^;]*var\(--danger-dot\)/);
    expect(open).not.toMatch(/background:[^;]*danger/);
    expect(sheet).not.toMatch(/\.tool-card\.is-error\s*\{[^}]*border-color:\s*var\(--danger-border\)/);
  });
});

describe("the open tool card separates head from body with a hairline", () => {
  test("the border appears with the open state only", async () => {
    const sheet = await css("tools.css");
    expect(ruleFor(sheet, ".tool-card.is-open .tool-head")).toMatch(
      /border-bottom:\s*1px solid var\(--border-faint\)/
    );
    expect(ruleFor(sheet, ".tool-head")).not.toMatch(/border-bottom/);
  });
});

describe("a dense code block hides its chrome until asked", () => {
  test("the head floats over the corner and reveals on hover AND focus", async () => {
    const sheet = await css("tools.css");
    const head = ruleFor(sheet, ".code-block.is-dense .code-block-head");
    expect(head).toMatch(/position:\s*absolute/);
    expect(head).toMatch(/opacity:\s*0/);
    // Keyboard reachability: focusing the wrap/copy buttons must reveal them.
    expect(sheet).toContain(".code-block.is-dense:focus-within .code-block-head");
  });
});

describe("the collapsed dock pill centers its row", () => {
  test("the head's vertical padding is symmetric", async () => {
    const sheet = await css("agents.css");
    const head = ruleFor(sheet, ".agents-dock-head");
    const match = /padding:\s*(\d+)px\s+\d+px\s+(\d+)px/.exec(head);
    expect(match).not.toBeNull();
    // The old 6px-top / 2px-bottom split sat the chevron, label, and actions
    // 2px low whenever the dock was collapsed (the head IS the whole pill
    // then, with no list below to balance it).
    expect(match![1]).toBe(match![2]);
  });
});

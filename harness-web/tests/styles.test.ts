import { describe, expect, test } from "bun:test";

async function css(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

/** The declaration block for one selector, so a rule can be asserted in isolation. */
function ruleFor(sheet: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`).exec(sheet);
  if (!match) throw new Error(`no rule for ${selector}`);
  return match[1];
}

describe("tool row never collapses either label to zero", () => {
  test("both the headline and the subtitle keep a min-width floor", async () => {
    const sheet = await css("tools.css");
    // A `flex: 1 1 0` with `min-width: 0` is what squeezed the subtitle to
    // exactly 0px at every width from 800 to 1200 — no ellipsis, no glyph, no
    // hover target. Both labels now carry a floor in ch.
    expect(ruleFor(sheet, ".tool-headline")).toMatch(/min-width:\s*\d+ch/);
    expect(ruleFor(sheet, ".tool-subtitle")).toMatch(/min-width:\s*\d+ch/);
    expect(ruleFor(sheet, ".tool-subtitle")).not.toMatch(/flex:\s*1 1 0/);
  });

  test("below 900px the two labels stack instead of competing", async () => {
    const sheet = await css("tools.css");
    expect(sheet).toMatch(/@media \(max-width: 900px\)[\s\S]*?\.tool-title\s*\{[\s\S]*?flex-direction: column/);
  });
});

describe("subagent rows are fixed-height", () => {
  test("the meta line and its chips share one 16px box", async () => {
    const sheet = await css("tools.css");
    expect(ruleFor(sheet, ".subagent-meta")).toMatch(/height:\s*16px/);
    expect(ruleFor(sheet, ".subagent-meta .tool-badge")).toMatch(/padding-block:\s*0/);
    expect(ruleFor(sheet, ".subagent-meta .tool-badge")).toMatch(/line-height:\s*16px/);
    // The activity line was min-height, which grows; a fixed box cannot.
    expect(ruleFor(sheet, ".subagent-activity")).toMatch(/height:\s*17px/);
    expect(ruleFor(sheet, ".subagent-activity")).not.toMatch(/min-height/);
  });
});

describe("assistant text keeps one origin", () => {
  test("the work rail is drawn inside the indent, not added to it", async () => {
    const sheet = await css("transcript.css");
    // Any padding-left or border-left on .turn-work reintroduces the 14px
    // sideways jump a paragraph made when it was reclassified from tail to work.
    const work = ruleFor(sheet, ".turn-work");
    expect(work).not.toMatch(/padding-left/);
    expect(work).not.toMatch(/border-left/);
    expect(ruleFor(sheet, ".turn-body")).toMatch(/padding-left:\s*var\(--rail-indent\)/);
    expect(sheet).toContain(".turn-work::before");
  });
});

describe("dock shares one text origin", () => {
  test("status, composer, and hints all resolve from --dock-indent", async () => {
    const sheet = await css("dock.css");
    expect(ruleFor(sheet, ".status-strip")).toContain("var(--dock-indent)");
    expect(ruleFor(sheet, ".composer-hints")).toContain("var(--dock-indent)");
    // The indicator is absolutely positioned so a 6px dot and 18px working dots
    // leave the label on the same x.
    expect(sheet).toContain(".status-strip > .status-dot");
    expect(sheet).toContain(".status-strip > .working-dots");
  });

  test("hints never wrap and drop out progressively instead", async () => {
    const sheet = await css("dock.css");
    expect(ruleFor(sheet, ".composer-hint")).toMatch(/white-space:\s*nowrap/);
    expect(sheet).toMatch(/@media \(max-width: 700px\)[\s\S]*?is-hint-mode/);
    expect(sheet).toMatch(/@media \(max-width: 560px\)[\s\S]*?is-hint-newline/);
    // Each hint owns its separator, so hiding one can never orphan a dot.
    expect(sheet).toContain(".composer-hint:not(:first-child)::before");
  });
});

describe("every interactive control answers the pointer", () => {
  test("the send button has a hover state", async () => {
    const sheet = await css("cards.css");
    expect(sheet).toContain(".btn-send:hover:not(:disabled)");
    expect(ruleFor(sheet, ".btn-send:hover:not(:disabled)")).toContain("--claude-btn-hover");
  });

  test("the primary button has one too", async () => {
    const sheet = await css("cards.css");
    expect(sheet).toContain(".btn-primary:hover:not(:disabled)");
  });
});

describe("the jump pill never covers transcript content", () => {
  test("the wrap reserves room for it instead of letting it overlay text", async () => {
    const sheet = await css("transcript.css");
    // Reserved space below the scroller is what makes overlap impossible; a pill
    // positioned inside the scroller always covers the last ~27px of content.
    expect(ruleFor(sheet, ".transcript-wrap.has-pill")).toMatch(/padding-bottom:\s*33px/);
    expect(ruleFor(sheet, ".jump-pill")).toMatch(/bottom:\s*3px/);
  });
});

describe("disclosures animate rather than snap", () => {
  test("the clipped plan body eases its max-height", async () => {
    const sheet = await css("cards.css");
    expect(ruleFor(sheet, ".plan-body")).toMatch(/transition:\s*max-height 200ms var\(--ease\)/);
  });
});

describe("the user copy button pins to its bubble", () => {
  test("the absolute rule outranks .icon-btn's position: relative", async () => {
    // `.icon-btn { position: relative }` lives in cards.css, which index.css
    // imports AFTER transcript.css. At equal specificity the later rule wins, so
    // a bare `.user-msg-copy` selector loses and the button falls into the flow,
    // adding ~26px of dead height to every user bubble.
    const transcript = await css("transcript.css");
    const cards = await css("cards.css");
    expect(ruleFor(transcript, ".user-msg .user-msg-copy")).toMatch(/position:\s*absolute/);
    expect(transcript).not.toMatch(/\n\.user-msg-copy\s*\{/);
    expect(ruleFor(cards, ".icon-btn")).toMatch(/position:\s*relative/);
    // Order matters for the fix to hold: assert the import order it relies on.
    const index = await css("index.css");
    expect(index.indexOf("transcript.css")).toBeLessThan(index.indexOf("cards.css"));
  });
});

describe("the status indicator never touches the status text", () => {
  test("both indicator variants end the same distance before the text origin", async () => {
    const sheet = await css("dock.css");
    const base = await css("base.css");
    const indent = Number(/--dock-indent:\s*(\d+)px/.exec(base)![1]);
    // Working dots are 3 × 4px + 2 × 3px gaps = 18px; the idle dot is 6px.
    const dotsLeft = Number(
      /\.status-strip > \.working-dots\s*\{[^}]*var\(--dock-indent\) - (\d+)px/.exec(sheet)![1]
    );
    const dotLeft = Number(
      /\.status-strip > \.status-dot\s*\{[^}]*var\(--dock-indent\) - (\d+)px/.exec(sheet)![1]
    );
    expect(indent - dotsLeft + 18).toBe(indent - 6);
    expect(indent - dotLeft + 6).toBe(indent - 6);
  });
});

describe("the header survives a thin split pane", () => {
  test("both groups can shrink, so neither overprints the other", async () => {
    const sheet = await css("layout.css");
    // A flex item without `min-width: 0` refuses to shrink below its content
    // and simply overprints its neighbour — which is how the title button came
    // to sit on top of the cost badge below ~440px.
    for (const selector of [".header-left", ".header-right", ".menu"]) {
      expect(ruleFor(sheet, selector)).toMatch(/min-width:\s*0/);
    }
    expect(ruleFor(sheet, ".header-left")).toMatch(/flex:\s*1 1 auto/);
    expect(ruleFor(sheet, ".header-right")).toMatch(/flex:\s*0 1 auto/);
  });

  test("the elastic content ellipsizes rather than overflowing", async () => {
    const sheet = await css("layout.css");
    expect(ruleFor(sheet, ".title-btn")).toMatch(/overflow:\s*hidden/);
    expect(ruleFor(sheet, ".pill-label")).toMatch(/text-overflow:\s*ellipsis/);
    expect(ruleFor(sheet, ".pill-label")).toMatch(/min-width:\s*0/);
    expect(ruleFor(sheet, ".mode-pill,\n.model-pill,\n.icon-pill")).toMatch(/min-width:\s*0/);
  });

  test("the cost badge steps aside before the title has to", async () => {
    // The same figure is printed in every turn footer; the session title is
    // nowhere else in the pane.
    const sheet = await css("layout.css");
    expect(sheet).toMatch(/@media \(max-width: 460px\)[\s\S]*?\.cost-badge[\s\S]*?display: none/);
  });
});

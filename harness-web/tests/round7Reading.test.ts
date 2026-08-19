import { describe, expect, test } from "bun:test";

/**
 * Round-7 review, item 5: the transcript's reading experience, against the
 * note "it doesn't look good and readable — can't exactly tell why it looks
 * worse". Every assertion here is one of the measured causes, so a later
 * restyle that reintroduces one fails rather than quietly undoing the pass.
 * (Item 6's Synara rail shipped here too, then was removed entirely in round
 * 8 at the user's request — round5.test.ts holds the stays-retired guard.)
 */

async function css(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

/** The sheet with comments stripped, so retirement notes can name what died. */
async function rules(name: string): Promise<string> {
  return (await css(name)).replace(/\/\*[\s\S]*?\*\//g, "");
}

async function source(path: string): Promise<string> {
  return Bun.file(new URL(`../src/${path}`, import.meta.url).pathname).text();
}

function block(sheet: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(`(?:^|\\})\\s*${escaped}\\s*\\{([^}]*)\\}`, "m").exec(sheet);
  if (!match) throw new Error(`no rule for ${selector}`);
  return match[1];
}

describe("item 5: the answer is set at a READING size, not a chrome size", () => {
  test("the assistant's body is a full step above the pane's chrome", async () => {
    // It was 13.5px — the same size as the tool cards, the dock and the fold
    // rows — so the one thing on the page a reader actually reads was
    // typographically indistinguishable from the labels around it.
    const sheet = await rules("transcript.css");
    const size = Number(/font-size:\s*([\d.]+)px/.exec(block(sheet, ".assistant-text"))![1]);
    expect(size).toBeGreaterThanOrEqual(14.5);
  });

  test("the leading grows with the measure", async () => {
    // A longer line needs more space under it for the eye to find the start of
    // the next one; 1.6 was set for a shorter one.
    const sheet = await rules("transcript.css");
    const lead = Number(/line-height:\s*([\d.]+)/.exec(block(sheet, ".assistant-text"))![1]);
    expect(lead).toBeGreaterThanOrEqual(1.65);
  });

  test("the user's prompt is not a caption on its own reply", async () => {
    // Leaving the bubble at 13px while the answer moved up made the prompt read
    // as smaller print than the response to it.
    const sheet = await rules("transcript.css");
    for (const selector of [".user-msg", ".thread-user"]) {
      const size = Number(/font-size:\s*([\d.]+)px/.exec(block(sheet, selector))![1]);
      expect(size).toBeGreaterThanOrEqual(14);
    }
  });
});

describe("item 5: the markdown body has prose rhythm, not chrome rhythm", () => {
  test("paragraphs are separated by a real gap", async () => {
    // 8px on a 21.6px line is 0.37em — about a third of what prose wants — so
    // consecutive paragraphs read as one wrapped block.
    const sheet = await rules("content.css");
    const gap = Number(/margin:\s*0 0 ([\d.]+)em/.exec(block(sheet, ".md p"))![1]);
    expect(gap).toBeGreaterThanOrEqual(0.7);
  });

  test("list items are separated at all", async () => {
    // They sat 1px apart, which is not a gap: a five-item list rendered as a
    // solid slab of text with bullets in it.
    const sheet = await rules("content.css");
    const gap = Number(/margin:\s*([\d.]+)em/.exec(block(sheet, ".md li"))![1]);
    expect(gap).toBeGreaterThanOrEqual(0.25);
  });

  test("a heading belongs to the section BELOW it", async () => {
    // It opened 14px above and closed 6px below, so a heading sat nearer the
    // paragraph above it than the section it titles.
    const sheet = await rules("content.css");
    const heading = block(sheet, ".md h1,\n.md h2,\n.md h3,\n.md h4");
    const margin = /margin:\s*([\d.]+)em 0 ([\d.]+)em/.exec(heading)!;
    expect(Number(margin[1])).toBeGreaterThan(Number(margin[2]) * 2);
  });

  test("the vertical measures are in ems, so they hold at every mount size", async () => {
    // `.md` is mounted at four different sizes (answer, thinking trace, tool
    // output, plan card); px measures only ever suit one of them.
    const sheet = await rules("content.css");
    for (const selector of [".md p", ".md li", ".md blockquote"]) {
      expect(block(sheet, selector)).toMatch(/margin:[^;]*em/);
    }
  });

  test("a bold lead-in does not outweigh the heading above it", async () => {
    // This body is full of lead-ins ("Component organization:"); at 600 against
    // a 400 body the eye stopped on the label instead of reading through.
    const sheet = await rules("content.css");
    const weight = Number(/font-weight:\s*(\d+)/.exec(block(sheet, ".md strong"))![1]);
    expect(weight).toBeLessThan(600);
    expect(weight).toBeGreaterThanOrEqual(550);
  });
});

describe("item 5: the inline-code chip sits IN the line, not on top of it", () => {
  test("it draws no border", async () => {
    // A 1px outline is what turned a tinted run of text into a button sitting
    // in a sentence. A bed and a border are two ways to say the same thing.
    const sheet = await rules("content.css");
    expect(block(sheet, ".inline-code")).not.toMatch(/(?:^|;|\s)border:/);
  });

  test("its padding is in ems, so it cannot outgrow its line box", async () => {
    // It painted 19px tall inside a 21.6px line — 88% of the line it sat in —
    // because 1.5px of vertical padding does not scale with a body that does.
    const sheet = await rules("content.css");
    const padding = /padding:\s*([\d.]+)em\s+([\d.]+)em/.exec(block(sheet, ".inline-code"));
    expect(padding).not.toBeNull();
    // Horizontal padding separates the chip from the words beside it; vertical
    // padding only inflates it inside its line.
    expect(Number(padding![2])).toBeGreaterThan(Number(padding![1]));
  });

  test("it is optically level with the body rather than numerically below it", async () => {
    // 0.88em on a mono face — larger x-height, wider glyphs — reads as a size
    // change mid-sentence, not as a match.
    const sheet = await rules("content.css");
    const size = Number(/font-size:\s*([\d.]+)em/.exec(block(sheet, ".inline-code"))![1]);
    expect(size).toBeGreaterThanOrEqual(0.9);
  });

  test("it has its own bed token, not the code BLOCK's", async () => {
    // `--code-bg` is black at 30% in dark: a bed built to sink a code block
    // inside a card that already has a surface under it. On the bare near-black
    // transcript it rendered as nothing, and with the border gone there was no
    // chip left at all.
    const sheet = await rules("content.css");
    expect(block(sheet, ".inline-code")).toMatch(/background:\s*var\(--inline-code-bg\)/);
    const theme = await source("ui/theme.ts");
    expect(theme).toContain('"--inline-code-bg"');
    // In dark the bed must be a LIGHT veil — the only direction that separates
    // from near-black. This is the actual defect, so it is asserted by
    // direction and not merely by the token existing.
    const token = /"--inline-code-bg":\s*dark\s*\?\s*"([^"]+)"/.exec(theme);
    expect(token).not.toBeNull();
    expect(token![1]).toMatch(/rgba\(255,\s*255,\s*255/);
  });
});

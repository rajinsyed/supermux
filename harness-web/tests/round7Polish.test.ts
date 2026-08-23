import { describe, expect, test } from "bun:test";

/**
 * Round-7 review polish, items 1–4. Each assertion is a defect the round-7
 * screenshots actually showed; the negative ones stop the retired treatment
 * from drifting back in a later restyle.
 */

async function css(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

/** The sheet with comments stripped, so retirement notes can name what died. */
async function rules(name: string): Promise<string> {
  return (await css(name)).replace(/\/\*[\s\S]*?\*\//g, "");
}

describe("item 1: the trigger splits name from effort by weight, not punctuation", () => {
  test("no interpunct is drawn before the effort", async () => {
    const sheet = await rules("dock.css");
    expect(sheet).not.toMatch(/\.composer-model-effort::before/);
  });

  test("the name is a step bolder and the effort a tier dimmer", async () => {
    const sheet = await rules("dock.css");
    expect(/\.composer-model-label\s*\{([^}]*)\}/.exec(sheet)![1]).toMatch(
      /font-weight:\s*5[5-9]\d/
    );
    expect(/\.composer-model-effort\s*\{([^}]*)\}/.exec(sheet)![1]).toMatch(
      /color:\s*var\(--text-faint\)/
    );
  });
});

describe("item 2: the composer veil is a short ramp, not a hazed third of the pane", () => {
  test("the fade zone tops out under 60px", async () => {
    const sheet = await rules("dock.css");
    const veil = /\.dock::before\s*\{([^}]*)\}/.exec(sheet)![1];
    const top = Number(/top:\s*-(\d+)px/.exec(veil)![1]);
    expect(top).toBeLessThan(60);
    expect(top).toBeGreaterThanOrEqual(30);
  });
});

describe("item 3: delegated-work rows never light a slab under the pointer", () => {
  test("no hover/focus background on agent, workflow, browser, or dock rows", async () => {
    const agents = await rules("agents.css");
    const workflow = await rules("workflow.css");
    for (const [sheet, selector] of [
      [agents, ".agent-row"],
      [agents, ".dock-row-open"],
      [workflow, ".wf-row"],
      [workflow, ".wfb-agent-row"]
    ] as const) {
      const esc = selector.replace(/[.[\]]/g, "\\$&");
      for (const state of ["hover", "focus-visible"]) {
        const rule = new RegExp(`${esc}:${state}[^{]*\\{([^}]*)\\}`).exec(sheet);
        if (rule) expect(rule[1]).not.toMatch(/background:\s*var\(--surface-hover\)/);
      }
    }
  });

  test("keyboard focus still marks the row — a ring, since the wash is gone", async () => {
    const agents = await rules("agents.css");
    const workflow = await rules("workflow.css");
    expect(/\.agent-row:focus-visible\s*\{([^}]*)\}/.exec(agents)![1]).toMatch(/outline:/);
    expect(/\.wf-row:focus-visible\s*\{([^}]*)\}/.exec(workflow)![1]).toMatch(/outline:/);
  });
});

describe("item 4: the dock's stop control is legible at rest", () => {
  test("it is never hidden behind a hover reveal", async () => {
    const sheet = await rules("agents.css");
    const stop = /\.dock-stop\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(stop).not.toMatch(/opacity:\s*0/);
    // A ringed glyph in readable ink, warming to danger on hover.
    expect(stop).toMatch(/border:\s*1px solid/);
    expect(stop).toMatch(/color:\s*var\(--text-muted\)/);
    expect(/\.dock-stop:hover[^{]*\{([^}]*)\}/.exec(sheet)![1]).toMatch(/var\(--danger\)/);
  });
});

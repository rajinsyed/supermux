import { describe, expect, test } from "bun:test";

async function css(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

/**
 * The declaration block a selector participates in, so a rule can be asserted in
 * isolation. The selector may be one of several in a comma-separated group —
 * `.btn-send:hover` sharing its block with `.btn-send:focus-visible` is the same
 * rule, and a matcher that only accepts a lone selector would report it missing.
 */
function ruleFor(sheet: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(
    `(?:^|\\n)(?:[^{}]*,\\s*)?${escaped}\\s*(?:,[^{}]*)?\\{([^}]*)\\}`
  ).exec(sheet);
  if (!match) throw new Error(`no rule for ${selector}`);
  return match[1];
}

/** Every selector group in a sheet, split into its individual selectors. */
function selectorGroups(sheet: string): string[][] {
  const groups: string[][] = [];
  const pattern = /(?:^|\n)((?:[^{}\n]+,\n)*[^{}\n]+)\{/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(sheet)) !== null) {
    groups.push(match[1].split(",").map((one) => one.trim()).filter(Boolean));
  }
  return groups;
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
  test("the inline agent row's activity line owns a fixed box", async () => {
    // The round-3 SubagentCard's fixed-geometry contract, carried by its
    // round-4 successor: the compact AgentRow's live activity changes every
    // second and must not resize the row under the reader.
    const sheet = await css("agents.css");
    const activity = ruleFor(sheet, ".agent-row-activity");
    expect(activity).toMatch(/height:\s*15px/);
    expect(activity).not.toMatch(/min-height/);
    expect(activity).toMatch(/white-space:\s*nowrap/);
    expect(activity).toMatch(/text-overflow:\s*ellipsis/);
  });
});

describe("live workflow and task rows are fixed-height", () => {
  test("the workflow row's counts own a fixed 16px box", async () => {
    // Aggregates change every couple of seconds while a workflow runs, and a
    // summary line that grows on each of them reflows the whole transcript
    // below the row.
    const rows = await css("workflow.css");
    expect(ruleFor(rows, ".wf-row-summary")).toMatch(/height:\s*16px/);
    expect(ruleFor(rows, ".wf-row-summary")).not.toMatch(/min-height/);
  });

  test("the state chip is sized once and coloured per state", async () => {
    // A row that changes queued → running → done must not change WIDTH doing it,
    // or the whole agent list shuffles sideways as the workflow advances. The
    // floor is the WIDEST state's full box — RUNNING plus its 9px spinner and
    // 4px gap measured at 73px — because a 7ch floor let RUNNING outgrow it and
    // slide every label 18px right and 29px back over an agent's lifecycle.
    const sheet = await css("workflow.css");
    const chip = ruleFor(sheet, ".wf-state");
    const floor = Number(/min-width:\s*(\d+)px/.exec(chip)?.[1]);
    expect(floor).toBeGreaterThanOrEqual(74);
    expect(chip).toMatch(/height:\s*16px/);
    for (const state of ["is-running", "is-done", "is-error", "is-blocked", "is-cached", "is-stopped"]) {
      expect(sheet).toContain(`.wf-state.${state}`);
    }
  });

  test("the browser's own state chip is sized once too", async () => {
    // Same contract one level up: the detail pane's chip is the widest thing on
    // its head row, and a chip that resized as the agent advanced would slide
    // the agent's NAME sideways under the reader.
    const sheet = await css("workflow.css");
    const chip = ruleFor(sheet, ".wfb-state");
    expect(chip).toMatch(/min-width:\s*\d+px/);
    expect(chip).toMatch(/height:\s*18px/);
  });

  test("the agent-row dot is one shape for every state", async () => {
    // Thirty agents in a phase read as one column of colour only if the mark
    // never changes size; a pill per state would be thirty different widths.
    const sheet = await css("workflow.css");
    const dot = ruleFor(sheet, ".wfb-dot");
    expect(dot).toMatch(/width:\s*7px/);
    expect(dot).toMatch(/height:\s*7px/);
    for (const state of ["is-running", "is-done", "is-error", "is-cached"]) {
      expect(sheet).toContain(`.wfb-dot.${state}`);
    }
  });

  test("STOPPED is a real tint, one glance apart from QUEUED", async () => {
    // Stopped is the one state the USER caused; rendered as the queued grey it
    // read as the absence of a state.
    const sheet = await css("workflow.css");
    const stopped = ruleFor(sheet, ".wf-state.is-stopped");
    expect(stopped).toContain("var(--warning-soft)");
    expect(stopped).toContain("var(--warning)");
    expect(ruleFor(sheet, ".wf-stopped-chip")).toContain("var(--warning-soft)");
  });

  test("the model chip's glyph never squashes; the text is the give", async () => {
    const sheet = await css("tasks.css");
    expect(ruleFor(sheet, ".subagent-model svg")).toMatch(/flex-shrink:\s*0/);
    expect(ruleFor(sheet, ".subagent-model-name")).toMatch(/text-overflow:\s*ellipsis/);
  });

  test("the live activity line clips instead of wrapping", async () => {
    // The dock row's label and detail carry live text; a wrap would grow the
    // row and bounce the composer below the dock.
    const agents = await css("agents.css");
    for (const selector of [".dock-label", ".dock-detail"]) {
      expect(ruleFor(agents, selector)).toMatch(/white-space:\s*nowrap/);
      expect(ruleFor(agents, selector)).toMatch(/text-overflow:\s*ellipsis/);
    }
    // The browser's Activity section is the same promise: a tool summary
    // arriving every second must not change the detail pane's height.
    const flow = await css("workflow.css");
    const activity = ruleFor(flow, ".wfb-section-body.is-activity");
    expect(activity).toMatch(/white-space:\s*nowrap/);
    expect(activity).toMatch(/text-overflow:\s*ellipsis/);
  });
});

describe("the agents dock cannot displace the composer", () => {
  test("the list caps its height and scrolls, like the todo strip", async () => {
    // The round-3 TasksStrip's contract, inherited by the dock that replaced
    // it: a workflow that spawned nine agents must not push the input off
    // screen.
    const sheet = await css("agents.css");
    const rule = ruleFor(sheet, ".agents-dock-list");
    expect(rule).toMatch(/max-height:\s*\d+px/);
    expect(rule).toMatch(/overflow-y:\s*auto/);
  });

  test("a drill-in transcript scrolls inside the card rather than growing it", async () => {
    // An agent transcript is unbounded; without a cap one drill-in can be longer
    // than the pane and push everything after it off screen.
    const sheet = await css("tasks.css");
    const rule = ruleFor(sheet, ".drill-transcript");
    expect(rule).toMatch(/max-height:\s*min\(\d+px,\s*\d+vh\)/);
    expect(rule).toMatch(/overflow-y:\s*auto/);
  });
});

describe("the workflow browser is a view, not a card wedged into the transcript", () => {
  test("the transcript keeps a single row, and the run is browsed elsewhere", async () => {
    // Round-3 finding 6 was 643px of phases inline with no way to put them
    // away. Round 4 answers it by not putting them inline at all: the row is
    // one line high and the phases live in a full view.
    const sheet = await css("workflow.css");
    expect(ruleFor(sheet, ".wf-row")).toMatch(/min-height:\s*\d\dpx/);
    expect(sheet).not.toContain(".workflow-card");
  });

  test("the browser's own panes scroll inside it rather than growing the pane", async () => {
    // A thirty-agent run is unbounded in both columns; without caps one of them
    // pushes the hint bar — which carries the only Stop control — off screen.
    const sheet = await css("workflow.css");
    expect(ruleFor(sheet, ".wfb-phases")).toMatch(/overflow-y:\s*auto/);
    expect(ruleFor(sheet, ".wfb-right")).toMatch(/overflow-y:\s*auto/);
    expect(ruleFor(sheet, ".wf-browser")).toMatch(/min-height:\s*0/);
    // A prompt or an outcome is unbounded too, and caps viewport-relative so a
    // short split is not overrun.
    expect(ruleFor(sheet, ".wfb-section-body")).toMatch(/max-height:\s*min\(\d+px,\s*\d+vh\)/);
  });

  test("a narrow split stacks the two columns instead of clipping one", async () => {
    const sheet = await css("workflow.css");
    expect(sheet).toMatch(/@media \(max-width: 620px\)[\s\S]*?\.wfb-panes\s*\{[\s\S]*?grid-template-columns: 1fr/);
  });

  test("the selected phase keeps its treatment when the pointer leaves", async () => {
    // It is what the right pane is SHOWING; a selection that only existed under
    // the cursor would leave the two panes with nothing tying them together.
    const sheet = await css("workflow.css");
    expect(sheet).toContain(".wfb-phase-row.is-active");
    expect(ruleFor(sheet, ".wfb-phase-row.is-active")).toContain("var(--claude-soft)");
  });
});

describe("the quoted output tail is not a dark slab in a light dock", () => {
  test("it paints its own themed bed, never the raw terminal token", async () => {
    // Round-3 finding 8: `--terminal-bg` is dark ink in BOTH themes, so the
    // tail punched a near-black hole through the light dock for what is by
    // construction peripheral output.
    const sheet = await css("tasks.css");
    const tail = ruleFor(sheet, ".task-output .terminal");
    expect(tail).toContain("var(--terminal-quiet-bg)");
    expect(tail).not.toContain("var(--terminal-bg)");
    // Its ink follows the bed, or a light excerpt keeps dark-terminal text.
    expect(ruleFor(sheet, ".task-output .terminal-body")).toContain("var(--terminal-quiet-fg)");
  });

  test("the transcript's own Bash terminal is untouched", async () => {
    // The dark terminal in a Bash card is deliberate and stays: this fix is
    // scoped to the tail that lives in the dock.
    const sheet = await css("tools.css");
    expect(ruleFor(sheet, ".terminal")).toContain("var(--terminal-bg)");
  });

  test("every piece of its chrome follows the bed too", async () => {
    const sheet = await css("tasks.css");
    for (const selector of [
      ".task-output .terminal-more",
      ".task-output .terminal .copy-btn"
    ]) {
      expect(ruleFor(sheet, selector)).toMatch(/var\(--terminal-quiet-/);
    }
  });
});

describe("subagent nesting stops indenting before it runs out of pane", () => {
  test("a nested agent row indents once, not per level", async () => {
    // Nesting is unbounded on the wire; the round-4 tree renders each child
    // as one guided row (the `└` prefix carries the hierarchy) rather than the
    // old card-in-card indentation that walked content off a split pane.
    const sheet = await css("agents.css");
    expect(ruleFor(sheet, ".agent-row-wrap.is-nested")).toMatch(/padding-left:\s*\d+px/);
    expect(sheet).toContain(".agent-row-guide");
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

describe("keyboard focus is never the weaker affordance", () => {
  const SHEETS = [
    "base.css",
    "cards.css",
    "dock.css",
    "layout.css",
    "modal.css",
    "tasks.css",
    "tools.css",
    "transcript.css"
  ];
  /**
   * The only sanctioned exemption: a pointer-only affordance that is hidden
   * outright without a fine pointer and is kept out of the tab order
   * (`tabIndex={-1}` on every tick), so it has no keyboard state to design.
   */
  const POINTER_ONLY = new Set([".timeline-tick"]);

  test("every class with a :hover treatment has a matching focus rule", async () => {
    // Hover changes background AND border AND colour; a bare UA outline over an
    // unchanged surface is not a designed focus state. Anything styled for the
    // pointer must be styled for the keyboard, or the two drift apart again.
    const missing: string[] = [];
    for (const name of SHEETS) {
      const sheet = await css(name);
      for (const group of selectorGroups(sheet)) {
        for (const selector of group) {
          const match = /^(\.[A-Za-z0-9_-]+)(?::[a-z-]+(?:\([^)]*\))?)*:hover\b/.exec(selector);
          if (!match) continue;
          const base = match[1];
          if (
            POINTER_ONLY.has(base) ||
            sheet.includes(`${base}:focus-visible`) ||
            sheet.includes(`${base}:focus-within`)
          ) {
            continue;
          }
          missing.push(`${name} ${base}`);
        }
      }
    }
    expect(missing).toEqual([]);
  });

  test("the shared ring is a visible halo, not just the UA outline", async () => {
    const sheet = await css("base.css");
    expect(ruleFor(sheet, ":focus-visible")).toMatch(/box-shadow:[^;]*var\(--focus-ring\)/);
  });
});

describe("a semantic mode pill keeps its colour under the pointer", () => {
  test("the neutral hover override cannot reach a toned pill", async () => {
    const sheet = await css("layout.css");
    // Bypass is the red "all prompts skipped" signal; the old blanket rule
    // repainted it to the neutral grey exactly while the pointer was on it.
    const groups = selectorGroups(sheet);
    const neutral = groups.find((group) =>
      group.some((s) => s === ".menu-trigger:hover .model-pill")
    );
    expect(neutral).toBeDefined();
    expect(neutral!.some((s) => s === ".menu-trigger:hover .mode-pill")).toBe(false);
    expect(neutral!.some((s) => s === ".menu-trigger:hover .mode-pill.is-default")).toBe(true);
    expect(sheet).toContain(".menu-trigger:hover .mode-pill:not(.is-default)");
    // The toned hover is a deepening of the pill's own hue, so the label colour
    // — the thing that names the mode — never moves.
    expect(ruleFor(sheet, ".menu-trigger:hover .mode-pill:not(.is-default)")).not.toMatch(
      /(?:^|\s)color:/
    );
  });
});

describe("the copied toast is visible where copy buttons actually live", () => {
  test("it opens downward, away from every clipping ancestor", async () => {
    const cards = await css("cards.css");
    const tools = await css("tools.css");
    // `.code-block` and `.tool-card` both clip; the toast used to be painted
    // entirely outside them at `bottom: calc(100% + 4px)`.
    expect(ruleFor(tools, ".code-block")).toMatch(/overflow:\s*hidden/);
    expect(ruleFor(tools, ".tool-card")).toMatch(/overflow:\s*hidden/);
    const toast = ruleFor(cards, ".copy-toast");
    expect(toast).toMatch(/top:\s*calc\(100% \+ 4px\)/);
    expect(toast).not.toMatch(/bottom:/);
  });
});

describe("the expanded todo strip cannot displace the transcript", () => {
  test("the list caps its height and scrolls instead", async () => {
    const sheet = await css("dock.css");
    const rule = ruleFor(sheet, ".todo-strip-list");
    // Viewport-relative, not a flat pixel value: 168px is a quarter of a tall
    // pane but a third of a 600px one, where the fixed cap left the TodoWrite
    // card above clipped mid-glyph behind the dock.
    expect(rule).toMatch(/max-height:\s*min\(\d+px,\s*\d+vh\)/);
    expect(rule).toMatch(/overflow-y:\s*auto/);
    // A short pane gives up even less: 500px tall is an ordinary cmux split.
    expect(sheet).toMatch(/@media \(max-height: 560px\)[\s\S]*?\.todo-strip-list/);
  });
});

describe("the user copy button never lands on the message text", () => {
  test("the bubble reserves the button's footprint rather than overlapping it", async () => {
    const sheet = await css("transcript.css");
    // Reserved at rest, not on hover: a hover-time padding change reflows the
    // words under the pointer.
    const reserve = ruleFor(sheet, ".user-msg-body::before");
    expect(reserve).toMatch(/float:\s*right/);
    expect(reserve).toMatch(/width:\s*\d+px/);
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

describe("the user hover tools pin to their bubble", () => {
  test("the absolute rule outranks .icon-btn's position: relative", async () => {
    // `.icon-btn { position: relative }` lives in cards.css, which index.css
    // imports AFTER transcript.css. At equal specificity the later rule wins, so
    // an unscoped selector loses and the buttons fall into the flow, adding
    // ~26px of dead height to every user bubble. Pinning the ROW rather than
    // each button is what let rewind join copy without reintroducing that.
    const transcript = await css("transcript.css");
    const cards = await css("cards.css");
    expect(ruleFor(transcript, ".user-msg .user-msg-tools")).toMatch(/position:\s*absolute/);
    expect(transcript).not.toMatch(/\n\.user-msg-tools\s*\{/);
    expect(ruleFor(cards, ".icon-btn")).toMatch(/position:\s*relative/);
    // Order matters for the fix to hold: assert the import order it relies on.
    const index = await css("index.css");
    expect(index.indexOf("transcript.css")).toBeLessThan(index.indexOf("cards.css"));
  });

  test("the reserved float covers both buttons, not one", async () => {
    // The float reserves the tools' footprint on the first line so text never
    // runs under them. Sized for one button it clears copy and leaves rewind
    // sitting on the words.
    const sheet = await css("transcript.css");
    const reserve = ruleFor(sheet, ".user-msg-body::before");
    const width = Number(/width:\s*(\d+)px/.exec(reserve)![1]);
    expect(width).toBeGreaterThanOrEqual(40);
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

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
    // The round-3 SubagentCard's fixed-geometry contract, carried through
    // every successor: the row's live activity changes every second and must
    // not resize the row under the reader.
    const sheet = await css("agents.css");
    const activity = ruleFor(sheet, ".agent-row-activity");
    expect(activity).toMatch(/height:\s*16px/);
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
    // Viewport-relative like the todo strip: a fixed cap is a third of a short
    // cmux split.
    expect(rule).toMatch(/max-height:\s*min\(\d+px,\s*\d+vh\)/);
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
    // Nesting is unbounded on the wire; each child indents ONE fixed step
    // under its wrap rather than the old card-in-card indentation that walked
    // content off a split pane. The indent alone carries the hierarchy.
    const sheet = await css("agents.css");
    expect(ruleFor(sheet, ".agent-row-wrap.is-nested")).toMatch(/padding-left:\s*\d+px/);
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
    // The rail itself is gone — Cursor's output has no vertical line — and it
    // must stay gone: reintroducing ::before puts a hairline beside every turn.
    expect(sheet).not.toContain(".turn-work::before");
  });
});

describe("dock shares one text origin", () => {
  test("the exception strip still resolves from --dock-indent", async () => {
    const sheet = await css("dock.css");
    expect(ruleFor(sheet, ".status-strip")).toContain("var(--dock-indent)");
  });

  test("nothing is captioned UNDER the composer any more", async () => {
    // The hint row ("Delivered through Claude at the agent's next tool call.")
    // mounted and unmounted with the agent view, moving the bottom bar under it
    // every time. Reintroducing a caption row below the pill brings the layout
    // shift back with it.
    const sheet = await css("dock.css");
    for (const dead of [".composer-hints", ".composer-hint", ".composer-hints-spacer"]) {
      expect(() => ruleFor(sheet, dead)).toThrow();
    }
    const composer = await Bun.file(
      new URL("../src/ui/composer/Composer.tsx", import.meta.url).pathname
    ).text();
    expect(composer).not.toContain("composer-hints");
  });
});

describe("the exception strip is the only thing above the composer", () => {
  test("it draws no ambient indicator — it is not a status line", async () => {
    // The dot and the working dots existed to narrate ordinary activity; the
    // strip no longer has an ordinary state to narrate.
    const sheet = await css("dock.css");
    expect(sheet).not.toContain(".status-strip > .status-dot");
    expect(sheet).not.toContain(".status-strip > .working-dots");
  });

  test("both tones it can wear paint a bed, not just tinted text", async () => {
    // It appears a handful of times in a session, so it is allowed to look like
    // something; a bare grey line at 11.5px was indistinguishable from the
    // transcript scrolling behind it.
    const sheet = await css("dock.css");
    for (const selector of [".status-strip.is-error", ".status-strip.is-busy"]) {
      expect(ruleFor(sheet, selector)).toMatch(/background:/);
      expect(ruleFor(sheet, selector)).toMatch(/border-color:/);
    }
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
  /** Pointer-only affordances exempt from keyboard styling; none currently. */
  const POINTER_ONLY = new Set<string>([]);

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

describe("the jump pill floats over the transcript", () => {
  test("no reserved band under the scroller; the pill overlays content", async () => {
    const sheet = await css("transcript.css");
    // The pill is a floating overlay — reserving a blank band above the
    // composer reads as dead space (user report). The pill's own bed keeps the
    // text under it legible.
    expect(sheet).not.toContain(".transcript-wrap.has-pill");
    const pill = ruleFor(sheet, ".jump-pill");
    expect(pill).toMatch(/position:\s*absolute/);
    expect(pill).toMatch(/bottom:/);
  });

  test("it clears the FLOATING dock rather than parking behind the composer", async () => {
    // Round-7 item 6 moved the dock out of the flex column and over the
    // scroller, so the pill's wrapper now runs the pane's full height. A flat
    // `bottom: 12px` would put the one control that exists for a lost reader
    // underneath the composer, which is the worst possible place for it.
    const sheet = await css("transcript.css");
    const pill = ruleFor(sheet, ".jump-pill");
    expect(pill).toMatch(/bottom:\s*calc\(var\(--dock-height/);
    // With a measured height there must be a resting fallback, or the very
    // first frame — before the ResizeObserver has run — puts it at zero.
    expect(pill).toMatch(/var\(--dock-height,\s*\d+px\)/);
    // Inside a framed sub-view the FRAME clears the dock, so the pill sits on
    // its own scroller's last line instead of floating a composer-height up.
    expect(ruleFor(sheet, ".view-frame .jump-pill")).toMatch(/bottom:\s*\d+px/);
  });
});

describe("the composer floats over the transcript instead of consuming it", () => {
  test("the dock is positioned over the scroller, not a band beside it", async () => {
    // The dogfood report: "the prompt bar eats background space". The dock
    // LOOKED floating — glass, gaps, shadows — while occupying a solid strip of
    // the flex column that content could never enter, so the glass had nothing
    // behind it to be glass about.
    const sheet = await css("dock.css");
    const dock = ruleFor(sheet, ".dock");
    expect(dock).toMatch(/position:\s*absolute/);
    expect(dock).toMatch(/bottom:\s*0/);
    expect(dock).not.toMatch(/flex:\s*0 0 auto/);
    // The gaps BETWEEN the islands must pass the pointer through to the
    // transcript, or the float replaces a dead band with an invisible one.
    expect(dock).toMatch(/pointer-events:\s*none/);
    expect(ruleFor(sheet, ".dock > *")).toMatch(/pointer-events:\s*auto/);
  });

  test("the transcript reserves the dock's MEASURED height as bottom padding", async () => {
    // Content scrolls behind the glass, and the last message still has to come
    // to rest above it. A hardcoded pad would be wrong by a whole composer the
    // moment the draft grows to three lines or a banner opens.
    const sheet = await css("transcript.css");
    const inner = ruleFor(sheet, ".transcript-inner");
    expect(inner).toMatch(/--dock-reserve:\s*calc\(var\(--dock-height,\s*\d+px\)/);
    expect(inner).toMatch(/padding:[^;]*var\(--dock-reserve\)/);
    // A framed sub-view's own frame clears the dock, so its column must not
    // reserve the height a second time.
    expect(ruleFor(sheet, ".view-frame .transcript-inner")).toMatch(/padding-bottom:\s*\d+px/);
    expect(ruleFor(await css("layout.css"), ".view-frame")).toMatch(
      /margin:[^;]*var\(--dock-height/
    );
  });

  test("the veil behind it is a progressive blur, faded by a mask", async () => {
    // A flat translucent bar is the old band drawn differently: text would hit
    // a hard edge and vanish. The blur and its tint fade out TOGETHER under one
    // mask ramp, so the effect reads as depth.
    const sheet = await css("dock.css");
    const veil = ruleFor(sheet, ".dock::before");
    expect(veil).toMatch(/backdrop-filter:\s*blur\(/);
    expect(veil).toMatch(/-webkit-mask-image:\s*linear-gradient\(\s*to top/);
    expect(veil).toMatch(/\n\s+mask-image:\s*linear-gradient\(\s*to top/);
    // Fully applied at the bottom, fully clear at the top: a transcript
    // scrolled to the top carries no veil at all.
    expect(veil).toMatch(/rgba\(0, 0, 0, 1\) 0%/);
    expect(veil).toMatch(/rgba\(0, 0, 0, 0\) 100%/);
    // It never eats the pointer — the text behind it stays selectable.
    expect(veil).toMatch(/pointer-events:\s*none/);
  });

  test("the veil is tinted with the PAGE, so it is invisible over empty space", async () => {
    // The first cut tinted it `--panel`, the composer's own glass. In light
    // that token is paper LIGHTER than the page — correct for an island that
    // must read as lifted, wrong for a full-bleed layer: it painted a brighter
    // rectangle across the bottom third of the pane, and the mask's ramp
    // quantised into three flat 1/255 steps, drawing three hairline bands
    // straight across a window with no content there to hide. Page-tinted, the
    // veil cannot band (it fades page into page) and shows only where there is
    // something behind it.
    const sheet = await css("dock.css");
    const veil = ruleFor(sheet, ".dock::before");
    expect(veil).toMatch(/background:\s*var\(--page-bg\)/);
    expect(veil).not.toContain("var(--panel)");
    // Themed token, never a literal colour.
    expect(veil).not.toMatch(/background:[^;]*(?:#[0-9a-f]{3}|rgba?\()/i);
  });

  test("it spans the pane, not the dock's own content-capped column", async () => {
    // The dock is capped at the content column and centred. Inset to it, the
    // veil drew a lit rectangle with two visible vertical edges down the middle
    // of the pane — the transcript shares that cap but the page and the
    // scrollbar gutter do not.
    const veil = ruleFor(await css("dock.css"), ".dock::before");
    expect(veil).toMatch(/width:\s*100vw/);
    expect(veil).toMatch(/margin-left:\s*-50vw/);
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

describe("the composer pill's stroke is even the whole way round", () => {
  test("no inset highlight stacks on the shell's own border", async () => {
    // `--shadow-panel` is `inset 0 1px 0 rgba(255,255,255,.06)`. On a flat panel
    // that reads as glass catching the light; drawn INSIDE the pill's 1px
    // border it composites with it, and the top stroke rendered visibly heavier
    // than the other three (user report: "top border looks thicker").
    const sheet = await css("dock.css");
    const shell = ruleFor(sheet, ".composer-shell");
    expect(shell).toMatch(/border:\s*1px solid var\(--border\)/);
    expect(shell).not.toContain("--shadow-panel");
    expect(shell).not.toMatch(/box-shadow/);
  });
});

describe("the stop control is visibly a stop control", () => {
  test("it never paints its glyph in the page colour", async () => {
    // It shipped as an empty white circle: `color: var(--page-bg)` on a
    // `background: var(--text)` bed, which renders NOTHING at all when the page
    // is transparent (Ghostty transparency) and is barely there in light.
    const sheet = await css("cards.css");
    const stop = ruleFor(sheet, ".btn-stop");
    expect(stop).not.toContain("--page-bg");
    expect(stop).toContain("var(--claude-btn)");
    expect(stop).toContain("var(--on-claude)");
    // Its hover is a real colour change, like every other filled control.
    expect(ruleFor(sheet, ".btn-stop:hover:not(:disabled)")).toContain("--claude-btn-hover");
  });
});

describe("the framed sub-view is as wide as the text inside it", () => {
  test("the frame caps at the content column rather than the pane", async () => {
    // It was `margin: 16px 18px` — 18px from each PANE edge, whatever the pane's
    // width. On a wide window that made a 1400px card around a 760px column, so
    // the frame's border sat hundreds of pixels from anything it contained and
    // the card read as dead space with a hairline round it.
    const sheet = await css("layout.css");
    const frame = ruleFor(sheet, ".view-frame");
    expect(frame).toMatch(/width:\s*min\(/);
    expect(frame).toContain("var(--content-max)");
    // Centred, and never edge-to-edge: `margin: … 18px` in the shorthand is
    // what the fix replaces, so a horizontal `auto` is the assertion.
    expect(frame).toMatch(/margin:\s*\d+px auto/);
  });

  test("it still keeps an inset on a pane too narrow for the cap", async () => {
    const sheet = await css("layout.css");
    // The `100% - Npx` arm of the min() is what leaves the page showing at the
    // sides of a 600px split, where the content cap is not the binding one.
    expect(ruleFor(sheet, ".view-frame")).toMatch(/min\(100% - \d+px/);
  });
});

describe("the header survives a thin split pane", () => {
  test("both groups can shrink, so neither overprints the other", async () => {
    const sheet = await css("layout.css");
    // A flex item without `min-width: 0` refuses to shrink below its content
    // and simply overprints its neighbour — which is how the title button came
    // to sit on top of the cost badge below ~440px.
    for (const selector of [".header-left", ".header-right"]) {
      expect(ruleFor(sheet, selector)).toMatch(/min-width:\s*0/);
    }
    // `.menu` is the shared trigger wrapper and lives in the kit now, so the
    // promise it carries has to be asserted where it is actually declared —
    // every menu in the pane depends on it, not only this bar's three.
    expect(ruleFor(await css("menu.css"), ".menu")).toMatch(/min-width:\s*0/);
    expect(ruleFor(sheet, ".header-left")).toMatch(/flex:\s*1 1 auto/);
    expect(ruleFor(sheet, ".header-right")).toMatch(/flex:\s*0 1 auto/);
  });

  test("the elastic content ellipsizes rather than overflowing", async () => {
    const sheet = await css("layout.css");
    // The session title is gone from the bar; the path chip is what gives way
    // first now, and it clips rather than pushing the controls off the strip.
    // Asserted as RULES rather than as raw text, so the retirement note that
    // names the three dead classes can stay in the sheet.
    for (const dead of [".title-btn", ".title-text", ".title-input"]) {
      expect(() => ruleFor(sheet, dead)).toThrow();
    }
    expect(ruleFor(sheet, ".header-left")).toMatch(/overflow:\s*hidden/);
    expect(ruleFor(sheet, ".dir-chip-text")).toMatch(/text-overflow:\s*ellipsis/);
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

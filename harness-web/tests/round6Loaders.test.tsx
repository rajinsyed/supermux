import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { richSession } from "../src/dev/fixtures";
import { replayLines } from "../src/model/transcript";
import type { Turn } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { CopyButton } from "../src/ui/primitives/CopyButton";
import { Spinner, WorkingDots, WorkingGlyph } from "../src/ui/primitives/Spinner";
import { TurnView } from "../src/ui/transcript/TurnView";
import { UserMessage } from "../src/ui/transcript/UserMessage";

/**
 * Round-6 review items 1, 4, 9, 10 and 11.
 *
 * Every assertion here is a defect the round-6 screenshots actually showed, or a
 * regression that would silently undo one of the fixes. The theme through all of
 * them: the pane had ONE loading animation wearing four different meanings, and
 * two of its controls were permanently on screen saying things the reader could
 * see for themselves.
 */

afterEach(cleanup);

async function css(name: string): Promise<string> {
  return Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text();
}

async function source(path: string): Promise<string> {
  return Bun.file(new URL(`../src/${path}`, import.meta.url).pathname).text();
}

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

function settledTurn(): Turn {
  const model = replayLines(richSession);
  const turn = model.turns.find((candidate) =>
    candidate.blocks.some((block) => block.kind === "tool")
  );
  expect(turn).toBeDefined();
  return { ...(turn as Turn), state: "complete", folded: true } as Turn;
}

/**
 * Item 1. The round-5 line/dash spinner is replaced by an orbit — a dot
 * travelling a ring — everywhere, without a single call site being edited: the
 * exported names and prop signatures are the contract that carries it to the
 * menus, the workflow rows, the dock and the model menu.
 */
describe("the dash spinner is an orbit now, everywhere at once", () => {
  test("Spinner renders the orbit and nothing dash-shaped", () => {
    const { container } = mount(<Spinner />);
    const orbit = container.querySelector(".orbit");
    expect(orbit).not.toBeNull();
    // The round-5 classes are what the call sites would still be painting if
    // the swap had been done per-site instead of in the primitive.
    expect(container.querySelector(".spinner")).toBeNull();
    expect(container.querySelector(".sheen-bar")).toBeNull();
  });

  test("the size prop drives the ring's own geometry, not just its box", async () => {
    // The call sites run 8px (a status badge) to 14px (a view header). A fixed
    // border width is a heavy blob at one end of that range and a hairline at
    // the other, so the track and the dot are derived from --orbit-size.
    const { container } = mount(<Spinner size={9} />);
    const orbit = container.querySelector<HTMLElement>(".orbit")!;
    expect(orbit.style.getPropertyValue("--orbit-size")).toBe("9px");
    expect(orbit.style.width).toBe("9px");

    const sheet = await css("base.css");
    const rule = /\.orbit\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(rule).toMatch(/--orbit-track:[^;]*var\(--orbit-size\)/);
    expect(rule).toMatch(/--orbit-dot:[^;]*var\(--orbit-size\)/);
  });

  test("it animates a transform, so thirty of them cost one layer each", async () => {
    const sheet = await css("base.css");
    expect(sheet).toMatch(/@keyframes orbit-travel\s*\{[^}]*transform:\s*rotate\(360deg\)/);
    expect(/\.orbit\s*\{([^}]*)\}/.exec(sheet)![1]).toContain("animation: orbit-travel");
  });

  test("nothing in the pane still asks for the retired round-5 marks", async () => {
    const spinner = await source("ui/primitives/Spinner.tsx");
    expect(spinner).not.toContain("sheen-bar");
    expect(spinner).not.toContain('className={`spinner');
  });
});

/**
 * Item 4. The screenshot that opened this item had a running Workflow row and
 * the turn's "Working for 54s" wearing the SAME dash two lines apart. The three
 * states are three different animations now, and the mapping is asserted rather
 * than described.
 */
describe("each kind of waiting has its own motion", () => {
  test("the three marks are three different classes", () => {
    const orbit = mount(<Spinner />);
    const turn = mount(<WorkingDots />);
    const delegated = mount(<WorkingGlyph />);

    expect(orbit.container.querySelector(".orbit")).not.toBeNull();
    expect(delegated.container.querySelector(".dock-glyph.pxgrid")).not.toBeNull();

    // The turn's mark draws NO glyph: its label carries the animation, which is
    // the whole reason it no longer collides with a tool row's indicator.
    const anchor = turn.container.querySelector(".working-dots")!;
    expect(anchor.children.length).toBe(0);
  });

  test("the turn-level mark is the label, and it still has a live tick", async () => {
    const sheet = await css("transcript.css");
    // The sweep is declared in cards.css (which this change does not own); what
    // transcript.css owns is the anchor collapsing and the tick after the words.
    expect(/\.turn-live\s\.working-dots\s*\{([^}]*)\}/.exec(sheet)![1]).toMatch(/width:\s*0/);
    const tick = /\.turn-live-label::after\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(tick).toContain("animation: turn-tick");
    expect(sheet).toMatch(/@keyframes turn-tick/);
  });

  test("delegated rows breathe, and their names sweep SLOWER than the turn's", async () => {
    // Two sheens at the same tempo are one effect wearing two labels, which is
    // the round-5 state this item exists to undo. The gap is the design.
    const agents = await css("agents.css");
    const cards = await css("cards.css");
    const rowTempo = Number(
      /\.dock-glyph \+ \.dock-label,[\s\S]*?animation: sheen-sweep ([\d.]+)s/.exec(agents)![1]
    );
    const turnTempo = Number(
      /\.turn-live \.working-dots \+ \.turn-live-label\s*\{[\s\S]*?animation: sheen-sweep ([\d.]+)s/.exec(
        cards
      )![1]
    );
    expect(rowTempo).toBeGreaterThan(turnTempo);
    expect(/\.dock-glyph\s*\{([^}]*)\}/.exec(agents)).not.toBeNull();
  });

  test("delegated work is a pixel grid, split by kind: orbit for agents, drive for workflows", () => {
    // The round-6 first cut gave every delegated row one breathing pip, which
    // the next review read as "the same dot again". The reference grid carries
    // two patterns, and the split is the point: a subagent's comet laps the
    // perimeter (8 lit cells, dark centre), a workflow's chevron lights all 9.
    const agent = mount(<WorkingGlyph variant="orbit" />);
    const workflow = mount(<WorkingGlyph variant="drive" />);

    const agentGrid = agent.container.querySelector(".pxgrid.is-orbit")!;
    const workflowGrid = workflow.container.querySelector(".pxgrid.is-drive")!;
    expect(agentGrid.children.length).toBe(9);
    expect(workflowGrid.children.length).toBe(9);
    expect(agentGrid.querySelectorAll("i.is-off").length).toBe(1);
    expect(workflowGrid.querySelectorAll("i.is-off").length).toBe(0);

    // The patterns live in the per-cell delays; the comet's period (8 × 110ms)
    // and the wavefront's (650ms, shorter than its 360ms-max stagger sweep +
    // fade so two fronts are always in flight) come from the reference.
    const orbitDelays = [...agentGrid.querySelectorAll("i:not(.is-off)")].map(
      (cell) => (cell as HTMLElement).style.animationDelay
    );
    expect(new Set(orbitDelays).size).toBe(8);
    expect((agentGrid.children[0] as HTMLElement).style.animationDuration).toBe("950ms");
    expect((workflowGrid.children[0] as HTMLElement).style.animationDuration).toBe("650ms");

    // The default is the subagent mark, so AgentRow's bare usage stays honest.
    const bare = mount(<WorkingGlyph />);
    expect(bare.container.querySelector(".pxgrid.is-orbit")).not.toBeNull();
  });

  test("every mark animates transform or opacity only", async () => {
    // Anything that animates a layout property makes the transcript reflow at
    // 60fps while a turn streams — the class of bug this pane has already paid
    // for twice.
    const sheet = await css("base.css");
    for (const name of ["orbit-travel", "pixel-on"]) {
      const frames = new RegExp(`@keyframes ${name}\\s*\\{([\\s\\S]*?)\\n\\}`).exec(sheet)![1];
      const properties = [...frames.matchAll(/([a-z-]+):\s*[^;]+;/g)].map((m) => m[1]);
      expect(properties.length).toBeGreaterThan(0);
      for (const property of properties) {
        expect(["transform", "opacity"]).toContain(property);
      }
    }
  });

  test("with motion off, every mark still reads as in-progress", async () => {
    // A stopped animation must not leave a mark that looks SETTLED, and must
    // never leave one frozen at whichever frame it happened to stop on. The
    // blanket rule at the foot of base.css halts them; each mark then needs a
    // declared RESTING state, or it freezes wherever it was.
    const sheet = await css("base.css");
    const blocks = [...sheet.matchAll(/@media \(prefers-reduced-motion: reduce\)/g)].map(
      (match) => sheet.slice(match.index, sheet.indexOf("\n}\n", match.index))
    );
    const declared = blocks.join("\n");
    // The grid rests half-lit, not at an arbitrary frame — and its dark centre
    // cell stays dark, so the resting orbit still shows its shape.
    expect(declared).toMatch(/\.pxgrid i\s*\{[^}]*opacity:\s*[\d.]+/);
    expect(declared).toMatch(/\.pxgrid i\.is-off\s*\{[^}]*opacity:\s*[\d.]+/);
    // The orbit rests as a dot parked on a full ring — a determinate-looking
    // gauge, which is what a static spinner ought to be.
    expect(declared).toContain(".orbit::before");
    expect(sheet).toMatch(/animation-duration:\s*0\.001ms\s*!important/);
  });
});

/**
 * Item 9. The collapsed turn header read "› Worked for 2m 30s   1 earlier tool
 * call" — a chevron on the wrong side and a permanent tally of rows one click
 * away.
 */
describe("the turn accordion is a sentence, not a control strip", () => {
  test("the collapsed header no longer prints an earlier-tool-call count", () => {
    const { container } = mount(<TurnView turn={settledTurn()} isLast={false} />);
    const head = container.querySelector(".fold-head")!;
    expect(container.querySelector(".fold-count")).toBeNull();
    expect(head.textContent).not.toMatch(/earlier tool call/);
    expect(head.textContent).toMatch(/Worked for|Stopped after|Failed after/);
  });

  test("the affordance is at the trailing edge, after the label", () => {
    const { container } = mount(<TurnView turn={settledTurn()} isLast={false} />);
    const head = container.querySelector(".fold-head")!;
    const children = Array.from(head.children);
    expect(children[children.length - 1].classList.contains("fold-toggle")).toBe(true);
    expect(children[0].classList.contains("fold-label")).toBe(true);
  });

  test("it is hidden at rest and revealed by hover AND by focus", async () => {
    const sheet = await css("transcript.css");
    const toggle = /\.fold-toggle\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(toggle).toMatch(/opacity:\s*0/);
    // `visibility` too, or the hidden state is an invisible click target parked
    // over the row's trailing edge.
    expect(toggle).toMatch(/visibility:\s*hidden/);
    // Keyboard reach must never be weaker than pointer reach.
    expect(sheet).toContain(".fold-head:hover .fold-toggle");
    expect(sheet).toContain(".fold-head:focus-visible .fold-toggle");
  });

  test("it looks like something you can press when it appears", async () => {
    // An affordance that shows up unannounced has to read as pressable at a
    // glance; a bare chevron does not.
    const sheet = await css("transcript.css");
    const toggle = /\.fold-toggle\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(toggle).toMatch(/background:/);
    expect(toggle).toMatch(/border:/);
    expect(toggle).toMatch(/border-radius:/);
  });

  test("a folded turn keeps the way in visible, since nothing else says so", async () => {
    // The count that used to announce hidden content is gone, so the one state
    // that is not self-evident from the transcript always shows its control.
    const sheet = await css("transcript.css");
    expect(/\.fold-head\.is-folded \.fold-toggle\s*\{([^}]*)\}/.exec(sheet)![1]).toMatch(
      /opacity:\s*1/
    );
    const { container } = mount(<TurnView turn={settledTurn()} isLast={false} />);
    expect(container.querySelector(".fold-head")!.classList.contains("is-folded")).toBe(true);
  });

  test("the whole row still toggles, from the pointer and from the keyboard", () => {
    const { container } = mount(<TurnView turn={settledTurn()} isLast={false} />);
    const head = container.querySelector<HTMLButtonElement>(".fold-head")!;
    // One focusable control, not a row plus a nested button (which is invalid
    // markup and unfocusable anyway).
    expect(head.tagName).toBe("BUTTON");
    expect(head.querySelectorAll("button").length).toBe(0);
    expect(head.getAttribute("aria-expanded")).toBe("false");

    fireEvent.click(head);
    expect(container.querySelector(".fold-head")!.getAttribute("aria-expanded")).toBe("true");
    expect(container.querySelector(".turn-work")!.classList.contains("is-folded")).toBe(false);
  });

  test("the STREAMING expander keeps its count — there the rows really are hidden", () => {
    const model = replayLines(richSession);
    const tools = model.turns
      .flatMap((turn) => turn.blocks)
      .filter((block) => block.kind === "tool")
      .slice(0, 3);
    const turn = {
      ...model.turns[0],
      blocks: tools,
      state: "streaming",
      endedAtMs: undefined,
      result: undefined
    } as Turn;
    const { container } = mount(<TurnView turn={turn} isLast />);
    expect(container.querySelector(".work-overflow")!.textContent).toMatch(/earlier tool call/);
  });
});

/** Item 10. The bubble was a 14px box with one chipped corner, not speech. */
describe("the user message is a properly rounded bubble", () => {
  test("the radius is generous, and the trailing corner is a tail not a chip", async () => {
    const sheet = await css("transcript.css");
    const bubble = /\.user-msg\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(bubble).toContain("border-radius: var(--r-xl)");
    const tail = Number(/border-bottom-right-radius:\s*(\d+)px/.exec(bubble)![1]);
    // A chip (the old --r-xs, 5px) reads as damage against an 18px edge; a tail
    // points the bubble at the user's side without breaking the shape.
    expect(tail).toBeGreaterThanOrEqual(6);
    expect(tail).toBeLessThan(12);
  });
});

/** Item 11. Copy and rewind were two bare icons floating in a corner. */
describe("the bubble's actions are a toolbar, not two floating glyphs", () => {
  test("they are grouped into one pill with its own bed", async () => {
    const sheet = await css("transcript.css");
    const tools = /\.user-msg \.user-msg-tools\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(tools).toMatch(/position:\s*absolute/);
    expect(tools).toMatch(/background:/);
    expect(tools).toMatch(/border:/);
    expect(tools).toContain("border-radius: var(--r-pill)");
  });

  test("hidden until hover, revealed on focus, and never a phantom click target", async () => {
    const sheet = await css("transcript.css");
    const tools = /\.user-msg \.user-msg-tools\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(tools).toMatch(/opacity:\s*0/);
    expect(tools).toMatch(/visibility:\s*hidden/);
    expect(tools).toMatch(/transition:[^;]*opacity/);
    expect(tools).toMatch(/transition:[^;]*transform/);
    expect(sheet).toContain(".user-msg:focus-within .user-msg-tools");
  });

  test("the reserved footprint covers the PILL, not two bare buttons", async () => {
    // The float is what keeps the words from running under the group; sized for
    // the old two loose buttons it leaves the pill's own padding on the text.
    const sheet = await css("transcript.css");
    const width = Number(
      /width:\s*(\d+)px/.exec(/\.user-msg-body::before\s*\{([^}]*)\}/.exec(sheet)![1])![1]
    );
    expect(width).toBeGreaterThanOrEqual(52);
  });

  test("both controls render inside the group", () => {
    const { container } = mount(<UserMessage text="hello" onRewind={() => {}} />);
    const tools = container.querySelector(".user-msg-tools")!;
    expect(tools.querySelector(".user-msg-rewind")).not.toBeNull();
    expect(tools.querySelector(".copy-btn")).not.toBeNull();
  });
});

describe("the copy confirmation never moves the layout", () => {
  test("both glyphs are always mounted, stacked on one cell", () => {
    // Swapping the element made success a hard cut AND resized the button (the
    // two glyphs have different advance widths), which shoved every neighbour
    // in an inline row. Stacked, the box is the max of the two forever.
    const { container } = mount(<CopyButton text="x" />);
    const stack = container.querySelector(".copy-glyph")!;
    expect(stack.querySelector(".copy-glyph-idle svg")).not.toBeNull();
    expect(stack.querySelector(".copy-glyph-done svg")).not.toBeNull();
  });

  test("the success state is a cross-fade, driven by a class on the button", async () => {
    const sheet = await css("base.css");
    expect(/\.copy-glyph\s*\{([^}]*)\}/.exec(sheet)![1]).toMatch(/display:\s*grid/);
    const idle = /\.copy-glyph-idle,\n\.copy-glyph-done\s*\{([^}]*)\}/.exec(sheet)![1];
    expect(idle).toMatch(/grid-area:\s*1 \/ 1/);
    expect(idle).toMatch(/transition:[^;]*opacity/);
    expect(sheet).toContain(".copy-btn.is-copied .copy-glyph-done");
    expect(sheet).toContain(".copy-btn.is-copied .copy-glyph-idle");
  });
});

/**
 * The glyphs themselves. Both were redrawn; these assert the properties that
 * made the old ones read as crude at 12px, so a future redraw cannot quietly
 * reintroduce them.
 */
describe("the copy and rewind glyphs are drawn on one grid", () => {
  test("the copy sheets rhyme: same size, same radius, even margins", async () => {
    const icons = await source("ui/Icons.tsx");
    const copy = /export const Copy = [\s\S]*?\n  \);/.exec(icons)![0];
    const rect = /<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)" rx="([\d.]+)"/.exec(
      copy
    )!;
    const [, x, y, w, h] = rect.map(Number);
    // Square, and its far edges 2px from the 16-unit box — the old draw ran
    // 2.25 in on one side and 2.25 out on the other, so the glyph sat off
    // centre in every button that holds it.
    expect(w).toBe(h);
    expect(16 - (x + w)).toBe(2);
    expect(y).toBe(x);
  });

  test("the rewind arrow's head terminates its own stroke", async () => {
    // The old draw ended the arc at (4.35, 4.22) and parked a corner bracket at
    // (2.25, 5.75) — the head read as a stray tick beside an almost-closed ring.
    const icons = await source("ui/Icons.tsx");
    const rewind = /export const Rewind = [\s\S]*?\n  \);/.exec(icons)![0];
    const arcEnd = /a6 6 0 1 0 ([\d.]+) ?-?([\d.]+)/.exec(rewind);
    expect(arcEnd).not.toBeNull();
    // A true 6-radius circle on the box's own centre, so the ring meets all four
    // margins evenly rather than floating small inside a 16-unit box.
    expect(rewind).toContain("M2 8a6 6 0 1 0");
    // The bracket's corner and the arc's end are the same point (3.76, 3.76 →
    // the bracket spans x 2→5.33 and y 2→5.33).
    expect(rewind).toContain('d="M2 2v3.33h3.33"');
  });

  test("both still declare an aria-hidden, focusable-false SVG", async () => {
    // They are decoration inside labelled buttons; a focusable SVG in IE-legacy
    // mode or an unlabelled img role would add two dead tab stops per bubble.
    const { container } = mount(<UserMessage text="hi" onRewind={() => {}} />);
    for (const svg of container.querySelectorAll("svg")) {
      expect(svg.getAttribute("aria-hidden")).toBe("true");
      expect(svg.getAttribute("focusable")).toBe("false");
    }
  });
});

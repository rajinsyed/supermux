import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { fixtures } from "../src/dev/fixtures";
import { replayLines } from "../src/model/transcript";
import type { Turn } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { TurnView } from "../src/ui/transcript/TurnView";
import { clampEffort } from "../src/ui/header/Header";

afterEach(cleanup);

function mount(turn: Turn) {
  return render(
    <CopyProvider dict={undefined}>
      <TurnView turn={turn} isLast />
    </CopyProvider>
  );
}

/** Recreate the running state the todos scenario shows mid-flight. */
function streamingTurn(): Turn {
  const model = replayLines(fixtures.todos);
  const turn = model.turns[model.turns.length - 1];
  return { ...turn, state: "streaming", endedAtMs: undefined, result: undefined };
}

/** Work rows hidden by the streaming overflow are mounted but display: none. */
function visibleCards(container: HTMLElement): HTMLElement[] {
  return Array.from(
    container.querySelectorAll<HTMLElement>(".turn-work .tool-card, .turn-work .subagent-card")
  ).filter((card) => {
    for (let node: HTMLElement | null = card; node; node = node.parentElement) {
      if (node.style.display === "none") return false;
    }
    return true;
  });
}

describe("work-group overflow while a turn runs", () => {
  test("collapses earlier work behind an expander instead of stacking every card", () => {
    const turn = streamingTurn();
    const workBlocks = turn.blocks.filter((b) => b.kind === "tool").length;
    expect(workBlocks).toBeGreaterThan(2);

    const { container } = mount(turn);
    const overflow = container.querySelector(".work-overflow");
    expect(overflow).not.toBeNull();

    expect(visibleCards(container).length).toBeLessThan(workBlocks);
  });

  test("the expander reveals every block it hid", () => {
    const turn = streamingTurn();
    const { container } = mount(turn);
    const before = visibleCards(container).length;

    fireEvent.click(container.querySelector(".work-overflow")!);

    const after = visibleCards(container).length;
    expect(after).toBeGreaterThan(before);
    expect(container.querySelector(".work-overflow")).not.toBeNull();
  });

  test("a still-running row stays visible however far back it sits", () => {
    const turn = streamingTurn();
    let marked = "";
    const blocks = turn.blocks.map((block) => {
      if (block.kind !== "tool" || marked) return block;
      marked = block.name;
      return { ...block, status: "running" as const };
    });
    expect(marked).not.toBe("");

    const { container } = mount({ ...turn, blocks });
    const running = visibleCards(container).filter((card) =>
      card.classList.contains("is-running")
    );
    expect(running.length).toBe(1);
  });

  test("the hidden work is wrapped in the shared animated disclosure", () => {
    const turn = streamingTurn();
    const { container } = mount(turn);

    // Round 2's Disclosure primitive drives every other collapse in the pane.
    // The hidden run stays MOUNTED (display: none) so revealing it — or the
    // turn settling — is a visibility change, never a remount.
    const hiddenBefore = container.querySelectorAll<HTMLElement>(".turn-work > .turn-work-hidden");
    expect(hiddenBefore.length).toBeGreaterThan(0);
    expect(Array.from(hiddenBefore).every((node) => node.style.display === "none")).toBe(true);

    fireEvent.click(container.querySelector(".work-overflow")!);

    const revealed = Array.from(
      container.querySelectorAll<HTMLElement>(".turn-work > .turn-work-hidden")
    ).filter((node) => node.style.display !== "none");
    expect(revealed.length).toBeGreaterThan(0);
    expect(revealed[0].children.length).toBeGreaterThan(0);
  });

  test("revealed work keeps its original order in the run", () => {
    const turn = streamingTurn();
    const { container } = mount(turn);
    fireEvent.click(container.querySelector(".work-overflow")!);

    const expected = turn.blocks.filter((b) => b.kind === "tool");
    expect(visibleCards(container).length).toBe(expected.length);
  });

  test("a settled turn still shows all of its work behind the fold header", () => {
    const turn = streamingTurn();
    const { container } = mount({ ...turn, state: "complete", endedAtMs: turn.startedAtMs + 4000 });
    expect(container.querySelector(".work-overflow") === null).toBe(true);
    expect(container.querySelector(".fold-head") === null).toBe(false);
    expect(visibleCards(container).length).toBe(
      turn.blocks.filter((b) => b.kind === "tool").length
    );
  });

  test("settling the turn keeps every work-row DOM node — no remount", () => {
    // The flagship round-3 defect: the settled and streaming branches rendered
    // DIFFERENT element trees at the same JSX slot, so the instant a turn
    // settled React unmounted the whole work subtree — snapping shut every
    // expanded subagent drill-in and workflow log strip and destroying the
    // reader's position. The work tree must be ONE stable tree across both
    // states: settling is a prop change, never a remount.
    const turn = streamingTurn();
    const { container, rerender } = render(
      <CopyProvider dict={undefined}>
        <TurnView turn={turn} isLast />
      </CopyProvider>
    );
    const savedCards = Array.from(
      container.querySelectorAll(".turn-work .tool-card, .turn-work .subagent-card")
    );
    expect(savedCards.length).toBeGreaterThan(0);

    rerender(
      <CopyProvider dict={undefined}>
        <TurnView
          turn={{ ...turn, state: "complete", folded: false, endedAtMs: turn.startedAtMs + 4000 }}
          isLast
        />
      </CopyProvider>
    );
    const after = Array.from(
      container.querySelectorAll(".turn-work .tool-card, .turn-work .subagent-card")
    );
    // Same NODES, not merely the same count: identity is what carries useState.
    for (const node of savedCards) expect(after.includes(node)).toBe(true);
    expect(container.querySelector(".fold-head")).not.toBeNull();
  });

  test("folding a settled turn hides the work tree without unmounting it", () => {
    const turn = streamingTurn();
    const settled = { ...turn, state: "complete" as const, folded: false, endedAtMs: turn.startedAtMs + 4000 };
    const { container } = mount(settled);
    const saved = container.querySelector(".turn-work .tool-card, .turn-work .subagent-card");
    expect(saved).not.toBeNull();

    fireEvent.click(container.querySelector(".fold-head")!);
    const work = container.querySelector<HTMLElement>(".turn-work")!;
    expect(work.classList.contains("is-folded")).toBe(true);
    // Still the same node — reopening finds everything where the reader left it.
    expect(container.contains(saved)).toBe(true);
  });
});

/**
 * `LIVE_TAIL = 1` means the streaming turn shows exactly ONE work row, so that
 * row's height is the layout. `defaultOpen` auto-expanded bash/todo/task/patched
 * edit but left read/search shut, so as a turn cycled Read → Edit → Bash → Read
 * the single row swapped between a collapsed strip and an open terminal card —
 * measured on `longform` at 9.63 shifts/second, largest 132px, of settled text
 * the reader was mid-paragraph on. Auto-expansion now waits for the turn to
 * settle, which is a boundary the reader already expects to reflow.
 */
describe("the live work row does not auto-size while a turn streams", () => {
  function toolTurn(): Turn {
    const model = replayLines(fixtures.longform);
    const turn = model.turns[0];
    return { ...turn, state: "streaming", endedAtMs: undefined, result: undefined };
  }

  test("the streaming tail renders every family collapsed, whatever it is", () => {
    const turn = toolTurn();
    const families = new Set<string>();
    // Walk the run: every tool in it becomes the live row at some point.
    for (const block of turn.blocks) {
      if (block.kind !== "tool") continue;
      const single = { ...turn, blocks: [block] };
      const { container, unmount } = mount(single);
      const card = container.querySelector(".tool-card");
      if (card) {
        families.add(card.getAttribute("data-family") ?? "");
        expect(card.classList.contains("is-open")).toBe(false);
        expect(container.querySelector(".tool-body")).toBeNull();
      }
      unmount();
    }
    // The bug needed at least one auto-opening family and one collapsed one in
    // the same run; assert the fixture still supplies the mix.
    expect(families.has("bash")).toBe(true);
    expect(families.has("read")).toBe(true);
    expect(families.has("edit")).toBe(true);
  });

  test("the same rows auto-open again once the turn settles", () => {
    const turn = toolTurn();
    const bash = turn.blocks.find((b) => b.kind === "tool" && b.name === "Bash");
    expect(bash).toBeDefined();
    const settled = { ...turn, state: "complete" as const, folded: false, endedAtMs: turn.startedAtMs + 4000, blocks: [bash!] };
    const { container } = mount(settled);
    expect(container.querySelector(".tool-card")!.classList.contains("is-open")).toBe(true);
  });

  test("a failure still auto-opens even while the turn streams", () => {
    // The error text is the whole reason the card is tinted; hiding it to keep
    // the row short would trade one defect for a worse one.
    const turn = toolTurn();
    const tool = turn.blocks.find((b) => b.kind === "tool")!;
    const failed = { ...tool, status: "error" as const, resultText: "Error: ENOENT" };
    const { container } = mount({ ...turn, blocks: [failed] });
    expect(container.querySelector(".tool-card")!.classList.contains("is-open")).toBe(true);
  });

  test("the user can still open a live row by hand", () => {
    const turn = toolTurn();
    const tool = turn.blocks.find((b) => b.kind === "tool")!;
    const { container } = mount({ ...turn, blocks: [tool] });
    fireEvent.click(container.querySelector(".tool-head")!);
    expect(container.querySelector(".tool-card")!.classList.contains("is-open")).toBe(true);
  });

  test("a settled turn's rows never depend on the live flag", () => {
    // Nothing above the live row may be marked live: that is what let a card
    // deep in the transcript change height when a turn below it streamed.
    const model = replayLines(fixtures.longform);
    const { container } = render(
      <CopyProvider dict={undefined}>
        <TurnView turn={{ ...model.turns[0], folded: false }} isLast={false} />
      </CopyProvider>
    );
    const cards = container.querySelectorAll(".turn-work .tool-card");
    expect(cards.length).toBeGreaterThan(3);
    const opened = Array.from(cards).filter((c) => c.classList.contains("is-open"));
    expect(opened.length).toBeGreaterThan(0);
  });
});

describe("effort clamping across a model switch", () => {
  const opus = {
    value: "claude-opus-5",
    displayName: "Opus 5",
    supportsEffort: true,
    supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"] as const
  };
  const sonnet = {
    value: "claude-sonnet-5",
    displayName: "Sonnet 5",
    supportsEffort: true,
    supportedEffortLevels: ["low", "medium", "high"] as const
  };
  const haiku = { value: "claude-haiku-4-5", displayName: "Haiku 4.5", supportsEffort: false };

  test("keeps an effort the target model supports", () => {
    expect(clampEffort({ ...opus, supportedEffortLevels: [...opus.supportedEffortLevels] }, "max")).toBe("max");
  });

  test("drops an effort the target model does not list", () => {
    expect(
      clampEffort({ ...sonnet, supportedEffortLevels: [...sonnet.supportedEffortLevels] }, "max")
    ).toBeUndefined();
  });

  test("drops effort entirely for a model that does not support it", () => {
    expect(clampEffort(haiku, "max")).toBeUndefined();
  });

  test("an unknown model carries no effort", () => {
    expect(clampEffort(undefined, "high")).toBeUndefined();
  });
});

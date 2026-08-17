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

describe("work-group overflow while a turn runs", () => {
  test("collapses earlier work behind an expander instead of stacking every card", () => {
    const turn = streamingTurn();
    const workBlocks = turn.blocks.filter((b) => b.kind === "tool").length;
    expect(workBlocks).toBeGreaterThan(2);

    const { container } = mount(turn);
    const overflow = container.querySelector(".work-overflow");
    expect(overflow).not.toBeNull();

    const rendered = container.querySelectorAll(".turn-work > .tool-card, .turn-work > .subagent-card");
    expect(rendered.length).toBeLessThan(workBlocks);
  });

  test("the expander reveals every block it hid", () => {
    const turn = streamingTurn();
    const { container } = mount(turn);
    const before = container.querySelectorAll(".turn-work > *").length;

    fireEvent.click(container.querySelector(".work-overflow")!);

    const after = container.querySelectorAll(".turn-work > *").length;
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
    expect(container.querySelectorAll(".turn-work .tool-card.is-running").length).toBe(1);
  });

  test("the hidden work is wrapped in the shared animated disclosure", () => {
    const turn = streamingTurn();
    const { container } = mount(turn);

    // Round 2's Disclosure primitive drives every other collapse in the pane.
    // A bare conditional swap here took the todos turn from 346px to 1072px in
    // one frame, directly under the reading position.
    expect(container.querySelector(".turn-work-hidden")).toBeNull();

    fireEvent.click(container.querySelector(".work-overflow")!);

    const revealed = container.querySelectorAll(".turn-work > .turn-work-hidden");
    expect(revealed.length).toBeGreaterThan(0);
    expect(revealed[0].children.length).toBeGreaterThan(0);
  });

  test("revealed work keeps its original order in the run", () => {
    const turn = streamingTurn();
    const { container } = mount(turn);
    fireEvent.click(container.querySelector(".work-overflow")!);

    const rendered = Array.from(
      container.querySelectorAll<HTMLElement>(".turn-work .tool-card, .turn-work .subagent-card")
    );
    const expected = turn.blocks.filter((b) => b.kind === "tool");
    expect(rendered.length).toBe(expected.length);
  });

  test("a settled turn still shows all of its work behind the fold header", () => {
    const turn = streamingTurn();
    const { container } = mount({ ...turn, state: "complete", endedAtMs: turn.startedAtMs + 4000 });
    expect(container.querySelector(".work-overflow") === null).toBe(true);
    expect(container.querySelector(".fold-head") === null).toBe(false);
    const cards = container.querySelectorAll(".turn-work > .tool-card");
    expect(cards.length).toBe(turn.blocks.filter((b) => b.kind === "tool").length);
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

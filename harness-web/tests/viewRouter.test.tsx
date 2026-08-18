import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { taskBridgeStub } from "./bridgeStub";
import {
  FWD_INNER_TOOL_USE_ID,
  FWD_OUTER_TOOL_USE_ID,
  fwdNestedFixture,
  RELAY_AGENT_TOOL_USE_ID,
  relayFixture
} from "../src/dev/fixtures/round4";
import { dockRows } from "../src/model/dock";
import {
  applyLine,
  applyLocalAction,
  createIndex,
  createModel,
  replayLines
} from "../src/model/transcript";
import type { RelayRecord, TranscriptModel } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { AgentsDock } from "../src/ui/dock/AgentsDock";
import { RelayChip } from "../src/ui/transcript/RelayChip";
import { TurnView } from "../src/ui/transcript/TurnView";
import { isRelayAck, relayInstruction } from "../src/ui/views/relay";
import {
  activeView,
  createStack,
  MAIN_VIEW,
  popView,
  pushView,
  viewKey
} from "../src/ui/views/viewStack";

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

/**
 * The navigation contract, as arithmetic on the stack.
 *
 * Escape means "one level back", and the only way that is true is if the route
 * REMEMBERS how it was reached: an agent opened from a workflow belongs to that
 * workflow, and deriving the trail from the agent's parentage instead would
 * send Escape somewhere the user has never been.
 */
describe("the view stack", () => {
  test("main is the floor and never pops", () => {
    const stack = createStack();
    expect(activeView(stack)).toEqual(MAIN_VIEW);
    expect(popView(stack)).toBe(stack);
  });

  test("opening pushes, escape pops back exactly one level", () => {
    let stack = createStack();
    stack = pushView(stack, { kind: "workflow", taskId: "wf1" });
    stack = pushView(stack, { kind: "agent", toolUseId: "a1" });
    expect(activeView(stack)).toEqual({ kind: "agent", toolUseId: "a1" });
    stack = popView(stack);
    // Back to the WORKFLOW, not to main: that is the whole reason this is a
    // stack rather than a current-view field.
    expect(activeView(stack)).toEqual({ kind: "workflow", taskId: "wf1" });
    stack = popView(stack);
    expect(activeView(stack)).toEqual(MAIN_VIEW);
  });

  test("re-opening the view you are already on does nothing", () => {
    // The dock row for the agent you are reading must not need two Escapes to
    // leave.
    const stack = pushView(createStack(), { kind: "agent", toolUseId: "a1" });
    expect(pushView(stack, { kind: "agent", toolUseId: "a1" })).toBe(stack);
  });

  test("re-entering a view already on the trail returns to it rather than stacking", () => {
    let stack = createStack();
    stack = pushView(stack, { kind: "workflow", taskId: "wf1" });
    stack = pushView(stack, { kind: "agent", toolUseId: "a1" });
    stack = pushView(stack, { kind: "workflow", taskId: "wf1" });
    // Three frames would mean the first Escape appeared to do nothing.
    expect(stack.length).toBe(2);
    expect(activeView(stack)).toEqual({ kind: "workflow", taskId: "wf1" });
  });

  test("opening main is a reset, not a push", () => {
    let stack = createStack();
    stack = pushView(stack, { kind: "agent", toolUseId: "a1" });
    stack = pushView(stack, { kind: "agent", toolUseId: "a2" });
    stack = pushView(stack, MAIN_VIEW);
    expect(stack).toEqual([MAIN_VIEW]);
  });

  test("view keys distinguish kinds that share an id", () => {
    expect(viewKey({ kind: "workflow", taskId: "t" })).not.toBe(viewKey({ kind: "shell", taskId: "t" }));
  });
});

describe("the agents dock", () => {
  const model = replayLines(fwdNestedFixture);
  const rows = dockRows(model);

  test("every row is a button that opens its own view", () => {
    const opened: string[] = [];
    const { container } = mount(
      <AgentsDock rows={rows} activeView={MAIN_VIEW} onOpen={(view) => opened.push(viewKey(view))} />
    );
    const buttons = Array.from(container.querySelectorAll(".dock-row-open"));
    expect(buttons.length).toBe(rows.length);
    fireEvent.click(buttons[1]!);
    expect(opened).toEqual([`agent:${FWD_OUTER_TOOL_USE_ID}`]);
  });

  test("a nested agent is indented under its parent and draws the tree guide", () => {
    const { container } = mount(
      <AgentsDock rows={rows} activeView={MAIN_VIEW} onOpen={() => undefined} />
    );
    const inner = container.querySelector(`[data-row-id="agent:${FWD_INNER_TOOL_USE_ID}"]`)!;
    expect(inner.getAttribute("data-depth")).toBe("2");
    expect(inner.querySelector(".dock-guide")).not.toBeNull();
    // A top-level agent has no parent to hang from, so it draws no guide.
    const outer = container.querySelector(`[data-row-id="agent:${FWD_OUTER_TOOL_USE_ID}"]`)!;
    expect(outer.querySelector(".dock-guide")).toBeNull();
  });

  test("a settled row persists, dimmed, with a frozen duration", () => {
    const { container } = mount(
      <AgentsDock rows={rows} activeView={MAIN_VIEW} onOpen={() => undefined} />
    );
    const outer = container.querySelector(`[data-row-id="agent:${FWD_OUTER_TOOL_USE_ID}"]`)!;
    expect(outer.className).toContain("is-settled");
    // A live `Elapsed` on a finished agent would keep counting, which is the
    // dock claiming the work is still going.
    expect(outer.querySelector(".dock-elapsed")!.textContent).not.toBe("");
    expect(outer.querySelector(".dock-state")!.textContent).toBe("Done");
  });

  test("the open view's row is marked current", () => {
    const { container } = mount(
      <AgentsDock
        rows={rows}
        activeView={{ kind: "agent", toolUseId: FWD_INNER_TOOL_USE_ID }}
        onOpen={() => undefined}
      />
    );
    const inner = container.querySelector(`[data-row-id="agent:${FWD_INNER_TOOL_USE_ID}"]`)!;
    expect(inner.className).toContain("is-active");
    expect(inner.querySelector(".dock-row-open")!.getAttribute("aria-current")).toBe("true");
  });

  test("one roving tabstop, and arrows walk the list", () => {
    const { container } = mount(
      <AgentsDock rows={rows} activeView={MAIN_VIEW} onOpen={() => undefined} />
    );
    const buttons = () =>
      Array.from(container.querySelectorAll(".dock-row-open")) as HTMLButtonElement[];
    // Tab must reach the list once, not once per row.
    expect(buttons().filter((node) => node.tabIndex === 0).length).toBe(1);
    const list = container.querySelector(".agents-dock-list")!;
    fireEvent.keyDown(list, { key: "ArrowDown" });
    expect(buttons()[1].tabIndex).toBe(0);
    fireEvent.keyDown(list, { key: "ArrowUp" });
    expect(buttons()[0].tabIndex).toBe(0);
  });

  test("Enter opens the focused row", () => {
    const opened: string[] = [];
    const { container } = mount(
      <AgentsDock rows={rows} activeView={MAIN_VIEW} onOpen={(view) => opened.push(viewKey(view))} />
    );
    const list = container.querySelector(".agents-dock-list")!;
    fireEvent.keyDown(list, { key: "ArrowDown" });
    fireEvent.keyDown(list, { key: "Enter" });
    expect(opened).toEqual([`agent:${FWD_OUTER_TOOL_USE_ID}`]);
  });

  test("Escape is NOT swallowed by the dock", () => {
    // It belongs to the view stack, which pops one level wherever focus is.
    // Handling it here would make esc mean two different things depending on
    // whether a row happened to have focus.
    const { container } = mount(
      <AgentsDock rows={rows} activeView={MAIN_VIEW} onOpen={() => undefined} />
    );
    const list = container.querySelector(".agents-dock-list")!;
    const event = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    act(() => {
      list.dispatchEvent(event);
    });
    expect(event.defaultPrevented).toBe(false);
  });

  test("a dock with nothing but main renders nothing", () => {
    const { container } = mount(
      <AgentsDock rows={dockRows(createModel())} activeView={MAIN_VIEW} onOpen={() => undefined} />
    );
    expect(container.querySelector(".agents-dock")).toBeNull();
  });

  test("Stop on a running row sends that row's own task id", async () => {
    const calls: string[] = [];
    window.supermuxHarnessMock = {
      ...taskBridgeStub,
      stopTask: (params: { taskId: string }) => {
        calls.push(params.taskId);
        return Promise.resolve();
      }
    } as never;
    const live = replayLines(relayFixture.slice(0, 20));
    const liveRows = dockRows(live);
    const stoppable = liveRows.filter((row) => row.stopTaskId !== undefined);
    expect(stoppable.length).toBe(1);
    const { container } = mount(
      <AgentsDock rows={liveRows} activeView={MAIN_VIEW} onOpen={() => undefined} />
    );
    // Exactly one Stop on screen: main has nothing to stop, and a settled row
    // must not offer to kill work that already ended.
    const buttons = container.querySelectorAll(".dock-stop");
    expect(buttons.length).toBe(1);
    fireEvent.click(buttons[0]!);
    await act(async () => {
      await Promise.resolve();
    });
    expect(calls).toEqual([stoppable[0].stopTaskId!]);
  });
});

/**
 * The relay, in the main transcript.
 *
 * The user typed one sentence; the wire carried a paragraph of instruction
 * wrapped around it, because there is no way to prompt an agent directly. Both
 * halves of that gap are covered here: the chip must show what the USER said,
 * and main's one-word acknowledgment must not read as an answer to them.
 */
describe("a relayed message in the main chat", () => {
  function relayedModel(): { model: TranscriptModel; relay: RelayRecord } {
    const index = createIndex();
    let model = createModel();
    model = applyLocalAction(
      model,
      index,
      {
        kind: "localSend",
        uuid: "relay-uuid-1",
        text: "focus on the parser",
        atMs: 1000,
        relay: { toolUseId: "toolu_x", description: "Slow summarizer" },
        backgrounded: true
      },
      1000
    );
    return { model, relay: model.relays["relay-uuid-1"] };
  }

  test("the model records the user's OWN text, not the wire instruction", () => {
    const { relay } = relayedModel();
    expect(relay.text).toBe("focus on the parser");
    expect(relay.toolUseId).toBe("toolu_x");
    expect(relay.state).toBe("sending");
  });

  test("the instruction sent to main quotes the user verbatim", () => {
    const wire = relayInstruction("Slow summarizer", "focus on the parser");
    expect(wire).toContain("'Slow summarizer' subagent");
    expect(wire).toContain("'focus on the parser'");
    expect(wire).toContain("reply only RELAYED");
  });

  test("the turn renders as a chip naming the agent, not as a user bubble", () => {
    const { model, relay } = relayedModel();
    const { container } = mount(
      <TurnView turn={model.turns[0]} isLast relay={relay} />
    );
    expect(container.querySelector(".user-msg")).toBeNull();
    const chip = container.querySelector(".relay-chip")!;
    expect(chip.textContent).toContain("Sent to Slow summarizer");
    expect(chip.textContent).toContain("focus on the parser");
  });

  test("the chip opens the agent it was addressed to", () => {
    const { relay } = relayedModel();
    const { container } = mount(<RelayChip relay={relay} />);
    // Without a router mounted the click is inert rather than throwing, which
    // is what lets a chip render in an export or a single-card test.
    expect(container.querySelector(".relay-chip-target")).not.toBeNull();
  });

  test("main's RELAYED is compacted to a receipt", () => {
    const { model, relay } = relayedModel();
    const turn = {
      ...model.turns[0],
      state: "complete" as const,
      blocks: [
        { kind: "text" as const, key: "t1", messageId: "m1", text: "RELAYED", streaming: false }
      ]
    };
    const { container } = mount(<TurnView turn={turn} isLast relay={relay} />);
    expect(container.querySelector(".relay-ack")).not.toBeNull();
    expect(container.querySelector(".assistant-text")).toBeNull();
  });

  test("anything main says BEYOND the acknowledgment still renders", () => {
    // Compacting that too would swallow a real answer — a refusal, or a note
    // that the agent could not be found.
    const { model, relay } = relayedModel();
    const turn = {
      ...model.turns[0],
      state: "complete" as const,
      blocks: [
        {
          kind: "text" as const,
          key: "t1",
          messageId: "m1",
          text: "I could not find that agent.",
          streaming: false
        }
      ]
    };
    const { container } = mount(<TurnView turn={turn} isLast relay={relay} />);
    expect(container.querySelector(".relay-ack")).toBeNull();
    expect(container.textContent).toContain("could not find that agent");
  });

  test("the ack matcher is anchored, so a mention of the word is not swallowed", () => {
    expect(isRelayAck("RELAYED")).toBe(true);
    expect(isRelayAck("  relayed. ")).toBe(true);
    expect(isRelayAck("I relayed it and then also did the work")).toBe(false);
    expect(isRelayAck(undefined)).toBe(false);
  });

  test("a turn WITHOUT a relay keeps its ordinary user bubble", () => {
    const index = createIndex();
    let model = createModel();
    model = applyLocalAction(
      model,
      index,
      { kind: "localSend", uuid: "u1", text: "hello", atMs: 1000 },
      1000
    );
    const { container } = mount(<TurnView turn={model.turns[0]} isLast />);
    expect(container.querySelector(".user-msg")).not.toBeNull();
    expect(container.querySelector(".relay-chip")).toBeNull();
  });
});

describe("a relay's delivery is confirmed by the agent's own thread", () => {
  test("the message shows pending immediately and is confirmed by the forwarded frame", () => {
    const index = createIndex();
    let model = replayLines(relayFixture.slice(0, 20));
    model = applyLocalAction(
      model,
      index,
      {
        kind: "localSend",
        uuid: "relay-2",
        text: "include the word PINEAPPLE",
        atMs: 5000,
        relay: { toolUseId: RELAY_AGENT_TOOL_USE_ID, description: "Slow summarizer" },
        backgrounded: true
      },
      5000
    );
    const thread = model.agentThreads[RELAY_AGENT_TOOL_USE_ID];
    const pending = thread.blocks.filter((b) => b.kind === "userText" && b.pending);
    // Shown at once: a composer that swallows what you typed until a round trip
    // completes reads as a send that failed.
    expect(pending.length).toBe(1);
    expect(model.relays["relay-2"].state).toBe("sending");

    const delivery = {
      type: "user",
      message: {
        role: "user",
        content: [{ type: "text", text: "ADDITIONAL GUIDANCE: include the word PINEAPPLE" }]
      },
      parent_tool_use_id: RELAY_AGENT_TOOL_USE_ID,
      uuid: "delivery-1"
    };
    const next = applyLine(model, index, delivery as never, 6000);
    const after = next.agentThreads[RELAY_AGENT_TOOL_USE_ID];
    // Confirmed IN PLACE, not drawn a second time: the user typed it once, and
    // the trip through main is plumbing rather than a second event.
    expect(after.blocks.filter((b) => b.kind === "userText" && b.pending).length).toBe(0);
    expect(
      after.blocks.filter(
        (b) => b.kind === "userText" && b.text.includes("PINEAPPLE")
      ).length
    ).toBe(1);
    expect(next.relays["relay-2"].state).toBe("delivered");
  });
});

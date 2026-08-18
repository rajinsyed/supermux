import { describe, expect, test } from "bun:test";
import {
  FWD_INNER_TOOL_USE_ID,
  FWD_OUTER_TOOL_USE_ID,
  fwdNestedFixture,
  RELAY_AGENT_TOOL_USE_ID,
  relayFixture
} from "../src/dev/fixtures/round4";
import { flattenThreads, isThreadRunning } from "../src/model/agentThreads";
import { dockRows } from "../src/model/dock";
import { applyEvent, applyLine, createIndex, createModel, replayLines } from "../src/model/transcript";
import type { TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";

function replayThrough(lines: ProtocolLine[], count: number): TranscriptModel {
  const index = createIndex();
  let model = createModel();
  for (const line of lines.slice(0, count)) model = applyLine(model, index, line, Date.now());
  return model;
}

/**
 * The round-4 attribution rule, against the frames that established it.
 *
 * fwd2.jsonl: main spawns `toolu_014M6…` ("Outer relay"); that agent's frames
 * carry parent=toolu_014M6…, and one of them is the `tool_use` announcing
 * `toolu_016qo…` ("Inner counter"), whose OWN frames then carry parent=toolu_016qo….
 * Everything about the tree — who is whose child, whose words are whose — is
 * that one rule applied twice, so these assert it at both levels.
 */
describe("agent threads build from the forwarded frames", () => {
  const model = replayLines(fwdNestedFixture);

  test("main's Agent tool_use opens a root thread", () => {
    expect(model.agentRootIds).toEqual([FWD_OUTER_TOOL_USE_ID]);
    const outer = model.agentThreads[FWD_OUTER_TOOL_USE_ID];
    expect(outer.description).toBe("Outer relay");
    expect(outer.subagentType).toBe("general-purpose");
    expect(outer.parentToolUseId).toBeUndefined();
  });

  test("an Agent tool_use INSIDE a thread opens a child of it", () => {
    const outer = model.agentThreads[FWD_OUTER_TOOL_USE_ID];
    expect(outer.childIds).toEqual([FWD_INNER_TOOL_USE_ID]);
    const inner = model.agentThreads[FWD_INNER_TOOL_USE_ID];
    expect(inner.parentToolUseId).toBe(FWD_OUTER_TOOL_USE_ID);
    expect(inner.description).toBe("Inner counter");
  });

  test("each thread holds only its OWN frames", () => {
    const outer = model.agentThreads[FWD_OUTER_TOOL_USE_ID];
    const inner = model.agentThreads[FWD_INNER_TOOL_USE_ID];
    // The inner agent ran a Bash; the outer one did not. If attribution were by
    // anything looser than the immediate parent id, that Bash would appear in
    // both threads.
    expect(inner.blocks.some((b) => b.kind === "tool" && b.name === "Bash")).toBe(true);
    expect(outer.blocks.some((b) => b.kind === "tool" && b.name === "Bash")).toBe(false);
    // The outer thread's own tool block is the Agent spawn, not the Bash.
    expect(outer.blocks.some((b) => b.kind === "tool" && b.name === "Agent")).toBe(true);
  });

  test("an agent's own prompt is the first user block of its thread", () => {
    const inner = model.agentThreads[FWD_INNER_TOOL_USE_ID];
    const first = inner.blocks[0];
    expect(first.kind).toBe("userText");
    expect(first.kind === "userText" && first.prompt).toBe(true);
    expect(first.kind === "userText" && first.text).toContain("echo inner-ok");
  });

  test("thinking and text are forwarded into the thread, not just tool calls", () => {
    // The entire point of `forwardSubagentText`: without it these blocks never
    // arrive and an agent view has nothing to render.
    const outer = model.agentThreads[FWD_OUTER_TOOL_USE_ID];
    expect(outer.blocks.some((b) => b.kind === "thinking")).toBe(true);
    expect(outer.blocks.some((b) => b.kind === "text")).toBe(true);
  });

  test("tool results settle the thread's copy of the block", () => {
    const inner = model.agentThreads[FWD_INNER_TOOL_USE_ID];
    const bash = inner.blocks.find((b) => b.kind === "tool" && b.name === "Bash");
    expect(bash?.kind === "tool" && bash.status).toBe("success");
    expect(bash?.kind === "tool" && bash.resultText).toContain("inner-ok");
  });

  test("task frames and AgentOutput enrich meta without creating threads", () => {
    const outer = model.agentThreads[FWD_OUTER_TOOL_USE_ID];
    expect(outer.status).toBe("completed");
    expect(outer.totalTokens).toBeGreaterThan(0);
    expect(outer.taskId).toBeDefined();
    // Exactly two agents ran, and exactly two threads exist: nothing in the
    // frame stream invents a third.
    expect(Object.keys(model.agentThreads).length).toBe(2);
  });

  test("flattening is depth-first, parent before child", () => {
    const flat = flattenThreads(model).map(({ thread, depth }) => [thread.toolUseId, depth]);
    expect(flat).toEqual([
      [FWD_OUTER_TOOL_USE_ID, 0],
      [FWD_INNER_TOOL_USE_ID, 1]
    ]);
  });

  test("mid-flight, both agents are live and the tree already has its shape", () => {
    // Cut just after the inner agent's prompt: the outer has spoken and
    // spawned, the inner has its brief and nothing else.
    const live = replayThrough(fwdNestedFixture, 40);
    expect(live.agentThreads[FWD_OUTER_TOOL_USE_ID].childIds).toEqual([FWD_INNER_TOOL_USE_ID]);
    expect(isThreadRunning(live.agentThreads[FWD_OUTER_TOOL_USE_ID])).toBe(true);
    expect(isThreadRunning(live.agentThreads[FWD_INNER_TOOL_USE_ID])).toBe(true);
  });
});

describe("the dock's rows", () => {
  test("main is first, then agents in tree order with an indent per level", () => {
    const model = replayLines(fwdNestedFixture);
    const rows = dockRows(model);
    expect(rows.map((row) => [row.kind, row.depth, row.label])).toEqual([
      ["main", 0, ""],
      ["agent", 1, "Outer relay"],
      ["agent", 2, "Inner counter"]
    ]);
  });

  test("a finished agent KEEPS its row, marked settled", () => {
    // The whole difference from the round-3 tasks strip, whose membership came
    // from `background_tasks_changed` and emptied the moment the CLI said
    // nothing was backgrounded — which is exactly when a user goes looking for
    // what an agent just did.
    const model = replayLines(fwdNestedFixture);
    const rows = dockRows(model).filter((row) => row.kind === "agent");
    expect(rows.length).toBe(2);
    expect(rows.every((row) => !row.running)).toBe(true);
    expect(rows.every((row) => row.status === "completed")).toBe(true);
    expect(model.backgroundTasks.length).toBe(0);
  });

  test("a settled row carries the tallies its work cost", () => {
    const model = replayLines(fwdNestedFixture);
    const outer = dockRows(model).find((row) => row.label === "Outer relay")!;
    expect(outer.totalTokens).toBeGreaterThan(0);
    expect(outer.endedAtMs).toBeDefined();
    expect(outer.stopTaskId).toBeUndefined();
  });

  test("a running agent's row offers the task to stop", () => {
    const live = replayThrough(fwdNestedFixture, 40);
    const outer = dockRows(live).find((row) => row.label === "Outer relay")!;
    expect(outer.running).toBe(true);
    expect(outer.stopTaskId).toBeDefined();
  });

  test("a backgrounded shell earns a row; a foreground one does not", () => {
    // `task_started` fires for foreground Bash too, which is why the round-3
    // strip took membership from `background_tasks_changed` alone. The dock
    // keeps that rule for shells and only relaxes PERSISTENCE.
    const model = replayLines(relayFixture);
    const shells = dockRows(model).filter((row) => row.kind === "shell");
    for (const row of shells) {
      expect(model.tasksById[row.view.kind === "shell" ? row.view.taskId : ""].isBackgrounded).toBe(
        true
      );
    }
  });

  test("an agent never appears twice — once as a thread and once as a task row", () => {
    const model = replayLines(relayFixture);
    const rows = dockRows(model);
    const agentIds = rows.filter((row) => row.kind === "agent").map((row) => row.label);
    expect(new Set(agentIds).size).toBe(agentIds.length);
    // The relay probe's agent is a `local_agent` task AND a thread; only the
    // thread may draw it, or the dock lists one agent as two things.
    expect(rows.filter((row) => row.label === "Slow summarizer").length).toBe(1);
  });
});

describe("a run boundary settles threads instead of leaving them spinning", () => {
  test("runStarted stops every live thread", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of fwdNestedFixture.slice(0, 40)) {
      model = applyLine(model, index, line, Date.now());
    }
    expect(isThreadRunning(model.agentThreads[FWD_OUTER_TOOL_USE_ID])).toBe(true);
    const next = applyEvent(model, index, { kind: "runStarted", runId: "r2" }, Date.now());
    // The threads SURVIVE — a resumed session's agents are still worth reading
    // — but none of them can still be running: the process producing their
    // frames is gone, and a dock row counting elapsed past it is a lie.
    expect(Object.keys(next.agentThreads).length).toBe(2);
    expect(isThreadRunning(next.agentThreads[FWD_OUTER_TOOL_USE_ID])).toBe(false);
    expect(next.agentThreads[FWD_OUTER_TOOL_USE_ID].endedAtMs).toBeDefined();
  });
});

describe("the relay probe's own thread", () => {
  const model = replayLines(relayFixture);

  test("the backgrounded agent has a thread with its whole conversation", () => {
    const thread = model.agentThreads[RELAY_AGENT_TOOL_USE_ID];
    expect(thread).toBeDefined();
    expect(thread.description).toBe("Slow summarizer");
    expect(thread.blocks.filter((b) => b.kind === "tool").length).toBe(4);
  });

  test("the guidance the agent received shows in its final answer", () => {
    // Probed end to end: main relayed it with SendMessage, the agent picked it
    // up at its next tool round, and quoted it back.
    const thread = model.agentThreads[RELAY_AGENT_TOOL_USE_ID];
    const text = thread.blocks
      .filter((b) => b.kind === "text")
      .map((b) => (b.kind === "text" ? b.text : ""))
      .join("\n");
    expect(text).toContain("PINEAPPLE");
  });
});

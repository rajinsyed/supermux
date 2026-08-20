import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, render } from "@testing-library/react";
import { createElement } from "react";
import { isThreadRunning } from "../src/model/agentThreads";
import { dockRows } from "../src/model/dock";
import { applyEvents, applyLine, applyLocalAction, createIndex, createModel } from "../src/model/transcript";
import { isTaskSettled } from "../src/model/tasks";
import type { Block, ToolBlock, TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { AgentRow } from "../src/ui/tools/AgentRow";

afterEach(cleanup);

/**
 * Item B — auto-resumed sessions must not revive dead subagents as "Working".
 *
 * The user's screenshot: after app reopen + automatic session restore, the
 * dock showed "12 Working" — every subagent of the replayed session listed
 * with an animating orbit grid and a Stop button, though nothing was running.
 *
 * Mechanism: disk history replays Task tool_use frames, which spawn agent
 * threads born "running" (createThread), and disk records carry no task frames
 * to ever settle them. `runStarted` settles threads at the process boundary,
 * but the restore-bootstrap replay never emits one — no process starts. So
 * `historyReplayed` has to be its own boundary: replayed history is by
 * definition not running.
 *
 * Fixture mirrors the real repro file
 * (~/.claude/projects/-Users-syedrajin-Documents-ryne/22a3aed2-*.jsonl, whose
 * replay produced 11 running threads out of 12): a main-thread assistant frame
 * spawning Agent tool_uses, plus each agent's own frames under its
 * parent_tool_use_id — and NO settling frames, exactly what the disk mapper
 * forwards (user/assistant records only).
 */

let seq = 0;
const uid = (p: string) => `${p}-${(seq += 1).toString(16)}`;

const AT = "2026-08-18T19:22:29.105Z";
const AT_MS = Date.parse(AT);

function diskUser(text: string): ProtocolLine {
  return {
    type: "user",
    message: { role: "user", content: text },
    parent_tool_use_id: null,
    session_id: "restored",
    uuid: uid("u"),
    timestamp: "2026-08-18T19:21:15.611Z"
  } as ProtocolLine;
}

function spawnAgents(ids: string[]): ProtocolLine {
  return {
    type: "assistant",
    message: {
      id: uid("m"),
      model: "gpt-5.6-sol",
      role: "assistant",
      content: ids.map((id, i) => ({
        type: "tool_use",
        id,
        name: "Agent",
        input: { description: `Agent ${i + 1}`, subagent_type: "Explore", prompt: "go" }
      }))
    },
    parent_tool_use_id: null,
    session_id: "restored",
    uuid: uid("a"),
    timestamp: AT
  } as ProtocolLine;
}

function agentFrame(parentToolUseId: string): ProtocolLine {
  return {
    type: "assistant",
    message: {
      id: uid("m"),
      model: "claude-haiku-4-5",
      role: "assistant",
      content: [{ type: "text", text: "agent working text" }]
    },
    parent_tool_use_id: parentToolUseId,
    session_id: "restored",
    uuid: uid("aa"),
    timestamp: AT
  } as ProtocolLine;
}

function replayedModel(agentCount: number): { model: TranscriptModel } {
  const ids = Array.from({ length: agentCount }, (_, i) => `toolu_agent_${i}`);
  const index = createIndex();
  let model = createModel();
  const lines = [diskUser("audit the repo"), spawnAgents(ids), ...ids.map(agentFrame)];
  for (const line of lines) model = applyLine(model, index, line, Date.now());
  model = applyLocalAction(model, index, { kind: "historyReplayed" }, Date.now());
  return { model };
}

function inlineAgentBlocks(model: TranscriptModel): ToolBlock[] {
  const agents: ToolBlock[] = [];
  const visit = (blocks: Block[]) => {
    for (const block of blocks) {
      if (block.kind !== "tool") continue;
      if (block.name === "Task" || block.name === "Agent") agents.push(block);
      visit(block.children);
    }
  };

  for (const turn of model.turns) visit(turn.blocks);
  return agents;
}

describe("item B: a replayed session's subagents are settled, not Working", () => {
  test("historyReplayed settles every replayed agent thread", () => {
    const { model } = replayedModel(12);
    expect(Object.keys(model.agentThreads).length).toBe(12);
    expect(Object.values(model.agentThreads).filter(isThreadRunning).length).toBe(0);
  });

  test("restored inline agent rows are terminal instead of loading forever", () => {
    const { model } = replayedModel(3);
    const blocks = inlineAgentBlocks(model);
    expect(blocks.length).toBe(3);

    for (const block of blocks) {
      expect(block.status === "pending" || block.status === "running").toBe(false);
      const status = block.subagent?.status;
      expect(status).toBeDefined();
      if (status !== undefined) expect(isTaskSettled(status)).toBe(true);
    }

    const view = render(
      createElement(
        CopyProvider,
        { dict: undefined },
        createElement(
          "div",
          null,
          blocks.map((block) => createElement(AgentRow, { key: block.key, block }))
        )
      )
    );
    expect(view.container.querySelector(".agent-row-glyph")).toBeNull();
    expect(view.container.textContent).not.toContain("Waiting to start");
  });

  test("the dock shows ZERO working rows after the replay — the '12 Working' screenshot", () => {
    const { model } = replayedModel(12);
    const rows = dockRows(model);
    expect(rows.filter((row) => row.running).length).toBe(0);
    // The dock is a live set: settled agents leave it entirely.
    expect(rows.filter((row) => row.kind === "agent").length).toBe(0);
  });

  test("settled threads carry their own last frame time, not wall-now", () => {
    const { model } = replayedModel(2);
    for (const thread of Object.values(model.agentThreads)) {
      expect(thread.endedAtMs).toBeDefined();
      // The replay happened 'now' but the work ended when its frames say.
      expect(thread.endedAtMs!).toBeLessThanOrEqual(AT_MS);
    }
  });

  test("task records are latched terminal too, so the strip and stop-all see nothing live", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of [diskUser("run"), spawnAgents(["toolu_x"]), agentFrame("toolu_x")]) {
      model = applyLine(model, index, line, Date.now());
    }
    // A task record that replay left unsettled (shape-wise; disk history does
    // not usually carry these, but a crashed pane's serialized model can).
    model = {
      ...model,
      tasksById: {
        task_1: { taskId: "task_1", taskType: "local_agent", status: "running", startedAtMs: 1, progressTick: 0 }
      },
      backgroundTasks: [{ taskId: "task_1", status: "running" }]
    };
    model = applyLocalAction(model, index, { kind: "historyReplayed" }, Date.now());
    expect(isTaskSettled(model.tasksById.task_1.status)).toBe(true);
    expect(model.backgroundTasks.length).toBe(0);
    expect(dockRows(model).filter((row) => row.running).length).toBe(0);
  });

  test("the explicit-resume path composes: replay settles, then runStarted is idempotent over it", () => {
    const { model: replayed } = replayedModel(3);
    // runStarted follows a resume (runRestart): already-settled threads stay
    // settled — the two boundaries agree.
    const afterRun = applyEvents(
      replayed,
      createIndex(),
      [{ kind: "runStarted", runId: "run-live" }],
      Date.now()
    );
    expect(Object.values(afterRun.agentThreads).filter(isThreadRunning).length).toBe(0);
    expect(dockRows(afterRun).filter((row) => row.running).length).toBe(0);
  });
});

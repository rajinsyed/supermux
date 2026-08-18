import { describe, expect, test } from "bun:test";
import {
  bgFixture,
  nestedFixture,
  shellsFixture,
  workflowFixture
} from "../src/dev/fixtures/round3";
import {
  applyEvent,
  applyLine,
  applyLocalAction,
  createIndex,
  createModel,
  replayLines
} from "../src/model/transcript";
import { runningForegroundBash, workStartedAtMs } from "../src/model/tasks";
import { mergeWorkflowProgress, groupByPhase } from "../src/model/workflow";
import type { Block, ToolBlock, TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";

function tools(model: TranscriptModel): ToolBlock[] {
  const out: ToolBlock[] = [];
  const walk = (blocks: Block[]) => {
    for (const block of blocks) {
      if (block.kind !== "tool") continue;
      out.push(block);
      walk(block.children);
    }
  };
  for (const turn of model.turns) walk(turn.blocks);
  return out;
}

function replayThrough(lines: ProtocolLine[], count: number) {
  const index = createIndex();
  let model = createModel();
  for (const line of lines.slice(0, count)) model = applyLine(model, index, line, Date.now());
  return {
    model,
    push(from: number, to?: number) {
      for (const line of lines.slice(from, to)) model = applyLine(model, index, line, Date.now());
      return model;
    },
    get current() {
      return model;
    }
  };
}

describe("the probes are the fixtures", () => {
  test("each round-3 fixture is the live probe plus the handshake reply", () => {
    expect(shellsFixture.length).toBe(49);
    expect(bgFixture.length).toBe(44);
    expect(workflowFixture.length).toBe(65);
    expect(nestedFixture.length).toBe(45);
    for (const fixture of [shellsFixture, bgFixture, workflowFixture, nestedFixture]) {
      expect((fixture[0] as { type?: string }).type).toBe("control_response");
      expect((fixture[1] as { subtype?: string }).subtype).toBe("init");
    }
  });
});

describe("tasksById is written by every task frame", () => {
  const model = replayLines(shellsFixture);
  const record = model.tasksById.bnopezzr7;

  test("task_started seeds the record with its type and launching tool", () => {
    expect(record).toBeDefined();
    expect(record.taskType).toBe("local_bash");
    expect(record.toolUseId).toBe("toolu_0141bFQK9n7L7m4uVMGWU1o3");
    expect(record.description).toBe("Print six ticks with 4-second sleeps between each");
  });

  test("the terminal notification lands status, output file and end time", () => {
    expect(record.status).toBe("stopped");
    expect(record.outputFile).toBe(
      "/private/tmp/claude-501/-private-tmp-harness-probe3-ws-shells/4d580bbb-e233-4870-a54a-cf8603b7ad06/tasks/bnopezzr7.output"
    );
    expect(record.endedAtMs).toBe(1786991421892);
  });

  test("a FOREGROUND Bash gets a record but never a strip row", () => {
    // Both Bash calls in the probe get task ids; only one is ever in the
    // background set, and the strip must reflect that and nothing else.
    const foreground = tools(model).find(
      (tool) => tool.name === "Bash" && tool.subagent?.taskId === undefined
    );
    expect(foreground).toBeDefined();
    expect(Object.keys(model.tasksById)).toEqual(["bnopezzr7"]);
  });
});

describe("background_tasks_changed REPLACES the set", () => {
  test("the strip is populated by the frame and emptied by the empty one", () => {
    const staged = replayThrough(shellsFixture, 25);
    expect(staged.current.backgroundTasks.map((task) => task.taskId)).toEqual(["bnopezzr7"]);
    staged.push(25, 47);
    // The kill's `tasks: []` is the whole set, so the strip empties.
    expect(staged.current.backgroundTasks).toEqual([]);
  });

  test("a row's detail is enriched from tasksById, not just the frame", () => {
    // The frame carries only task_id/task_type/description; everything else on
    // the row — the live status the CLI patched in — comes from the record.
    const staged = replayThrough(bgFixture, 24);
    const row = staged.current.backgroundTasks[0];
    expect(row.taskId).toBe("b20r5l4dg");
    expect(row.taskType).toBe("local_bash");
    expect(staged.current.tasksById.b20r5l4dg.isBackgrounded).toBe(true);
  });

  test("membership survives a frame arriving BEFORE task_started", () => {
    // In the shells probe `background_tasks_changed` races ahead of the
    // task_started for the same id; a row with no record yet must still be
    // recorded as backgrounded or the Bash card never earns its badge.
    const staged = replayThrough(shellsFixture, 25);
    expect(staged.current.tasksById.bnopezzr7.isBackgrounded).toBe(true);
  });
});

describe("runStarted clears the per-process task state", () => {
  test("a new run drops both the strip and the id map", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of shellsFixture.slice(0, 26)) model = applyLine(model, index, line, Date.now());
    expect(model.backgroundTasks.length).toBe(1);
    expect(Object.keys(model.tasksById).length).toBe(1);
    // Task ids are scoped to the PROCESS. Carried across a restart the strip
    // would offer Stop against ids the new process has never heard of.
    model = applyEvent(model, index, { kind: "runStarted", runId: "run-2" }, Date.now());
    expect(model.backgroundTasks).toEqual([]);
    expect(model.tasksById).toEqual({});
  });
});

describe("task_updated is a MERGE patch", () => {
  test("keys absent from the patch keep their previous values", () => {
    const staged = replayThrough(bgFixture, 22);
    const before = staged.current.tasksById.b20r5l4dg;
    expect(before.description).toBe("Print slow-1 through slow-8 with 3s delay each");
    expect(before.taskType).toBe("local_bash");
    // The patch is `{is_backgrounded: true}` alone.
    staged.push(22, 24);
    const after = staged.current.tasksById.b20r5l4dg;
    expect(after.isBackgrounded).toBe(true);
    expect(after.description).toBe(before.description);
    expect(after.taskType).toBe("local_bash");
    expect(after.toolUseId).toBe("toolu_016i2VPvtvJzj3Vqxz3gpkZS");
  });

  test("a task_progress description is activity, not a rename", () => {
    // "Gather: agent-beta" is what the workflow is DOING; letting it overwrite
    // the description renames the strip row several times a second.
    const model = replayLines(workflowFixture);
    const record = model.tasksById.wxajrgc4u;
    expect(record.description).toBe("Two agents return alpha and beta, merged into one result");
    expect(record.activity).toBe("Merge: merger");
  });
});

describe("task frames after the result never reopen the turn", () => {
  test("the workflow's post-result progress leaves the turn settled and idle", () => {
    const staged = replayThrough(workflowFixture, 47);
    const launching = staged.current.turns[0];
    expect(launching.state).toBe("complete");
    expect(launching.result).toBeDefined();
    expect(staged.current.activity.sessionState).toBe("idle");
    const turnCount = staged.current.turns.length;

    // Four more progress frames, the empty background set, the completion patch
    // and the notification — all AFTER the result.
    staged.push(47, 54);
    const after = staged.current;
    expect(after.turns.length).toBe(turnCount);
    expect(after.turns[0].state).toBe("complete");
    expect(after.turns[0].result).toBeDefined();
    expect(after.activity.sessionState).toBe("idle");
    // The work still landed — on the block and the record, which is where
    // post-result activity belongs.
    expect(after.tasksById.wxajrgc4u.status).toBe("completed");
    expect(after.tasksById.wxajrgc4u.workflow?.totals.done).toBe(3);
  });

  test("a turn whose workflow is still running does NOT fold", () => {
    // The result lands the instant the workflow is launched and its agents run
    // for another ten seconds. Folding on that frame hides the live progress
    // card the user is watching, mid-flight.
    const staged = replayThrough(workflowFixture, 47);
    expect(staged.current.turns[0].state).toBe("complete");
    expect(staged.current.turns[0].folded).toBe(false);
  });

  test("it folds once the background work actually settles", () => {
    const model = replayLines(workflowFixture);
    expect(model.turns[0].folded).toBe(true);
    expect(model.tasksById.wxajrgc4u.status).toBe("completed");
  });

  test("a user who opens the turn keeps it open when the work finishes", () => {
    // The deferred fold is a convenience, not a claim on the viewport: a turn
    // that collapses under the reader mid-read is worse than one left open.
    const index = createIndex();
    let model = createModel();
    for (const line of workflowFixture.slice(0, 47)) model = applyLine(model, index, line, Date.now());
    expect(model.turns[0].foldWhenTasksSettle).toBe(true);
    model = applyLocalAction(
      model,
      index,
      { kind: "toggleFold", turnId: model.turns[0].id, folded: false },
      Date.now()
    );
    for (const line of workflowFixture.slice(47)) model = applyLine(model, index, line, Date.now());
    expect(model.turns[0].folded).toBe(false);
  });

  test("an ordinary turn with no background work still folds on its result", () => {
    // The exemption is scoped to live BACKGROUND tasks; a normal turn must keep
    // folding, or the transcript stops collapsing entirely.
    const model = replayLines(nestedFixture);
    expect(model.turns[0].folded).toBe(true);
  });

  test("the CLI's own follow-up init opens a turn, and only that", () => {
    const model = replayLines(workflowFixture);
    expect(model.turns.length).toBe(2);
    expect(model.session.sessionId).toBe("8e022168-39a3-4eba-ade1-cc6a5b24c51a");
  });
});

describe("workflow_progress upsert semantics", () => {
  test("(type, index) replaces in place and array order is preserved", () => {
    const first = mergeWorkflowProgress(undefined, [
      { type: "workflow_phase", index: 1, title: "Gather" },
      { type: "workflow_phase", index: 2, title: "Merge" },
      { type: "workflow_agent", index: 1, label: "agent-alpha", phaseIndex: 1, state: "start", startedAt: 10 },
      { type: "workflow_agent", index: 2, label: "agent-beta", phaseIndex: 1, state: "start" }
    ]);
    expect(first!.agents.map((agent) => agent.label)).toEqual(["agent-alpha", "agent-beta"]);
    expect(first!.agents.map((agent) => agent.state)).toEqual(["running", "queued"]);

    // The next frame carries the SAME agents at new states, plus a third.
    const second = mergeWorkflowProgress(first, [
      { type: "workflow_phase", index: 1, title: "Gather" },
      { type: "workflow_phase", index: 2, title: "Merge" },
      { type: "workflow_agent", index: 1, label: "agent-alpha", phaseIndex: 1, state: "done", startedAt: 10, tokens: 5 },
      { type: "workflow_agent", index: 2, label: "agent-beta", phaseIndex: 1, state: "start", startedAt: 12 },
      { type: "workflow_agent", index: 3, label: "merger", phaseIndex: 2, state: "start" }
    ]);
    expect(second!.agents.length).toBe(3);
    expect(second!.agents.map((agent) => agent.label)).toEqual([
      "agent-alpha",
      "agent-beta",
      "merger"
    ]);
    expect(second!.agents.map((agent) => agent.state)).toEqual(["done", "running", "queued"]);
    expect(second!.phases.length).toBe(2);
    expect(second!.totals).toEqual({
      agents: 3,
      done: 1,
      running: 1,
      failed: 0,
      tokens: 5,
      toolCalls: 0
    });
  });

  test("logs append and a resent list does not duplicate them", () => {
    const first = mergeWorkflowProgress(undefined, [
      { type: "workflow_log", message: "starting" },
      { type: "workflow_log", message: "phase Gather" }
    ]);
    expect(first!.logs).toEqual(["starting", "phase Gather"]);
    const second = mergeWorkflowProgress(first, [
      { type: "workflow_log", message: "starting" },
      { type: "workflow_log", message: "phase Gather" },
      { type: "workflow_log", message: "phase Merge" }
    ]);
    expect(second!.logs).toEqual(["starting", "phase Gather", "phase Merge"]);
  });

  test("a frame with no progress array leaves the snapshot intact", () => {
    // Roughly half the real task_progress frames carry no array at all; blanking
    // the card on those would make it strobe once a second.
    const populated = mergeWorkflowProgress(undefined, [
      { type: "workflow_agent", index: 1, label: "one", state: "done" }
    ]);
    const after = mergeWorkflowProgress(populated, undefined);
    expect(after).toBe(populated);
    expect(after!.agents.length).toBe(1);
  });

  test("blocked and cached outrank the wire's three states", () => {
    const merged = mergeWorkflowProgress(undefined, [
      { type: "workflow_agent", index: 1, label: "b", state: "start", startedAt: 1, blocked: true },
      { type: "workflow_agent", index: 2, label: "c", state: "done", cached: true },
      { type: "workflow_agent", index: 3, label: "e", state: "error", blocked: true }
    ]);
    expect(merged!.agents.map((agent) => agent.state)).toEqual(["blocked", "cached", "error"]);
  });

  test("an agent whose phase was never declared still renders", () => {
    const merged = mergeWorkflowProgress(undefined, [
      { type: "workflow_phase", index: 1, title: "Gather" },
      { type: "workflow_agent", index: 1, label: "declared", phaseIndex: 1, state: "done" },
      { type: "workflow_agent", index: 2, label: "orphan", phaseIndex: 9, state: "done" }
    ]);
    const groups = groupByPhase(merged!);
    expect(groups.length).toBe(2);
    expect(groups[0].phase?.title).toBe("Gather");
    expect(groups[1].phase).toBeUndefined();
    expect(groups[1].agents.map((agent) => agent.label)).toEqual(["orphan"]);
  });
});

describe("the workflow probe reaches the block and the record", () => {
  const model = replayLines(workflowFixture);
  const block = tools(model).find((tool) => tool.name === "Workflow");

  test("the launching block carries the parsed workflow", () => {
    expect(block).toBeDefined();
    expect(block!.workflow!.phases.map((phase) => phase.title)).toEqual(["Gather", "Merge"]);
    expect(block!.workflow!.agents.map((agent) => agent.label)).toEqual([
      "agent-alpha",
      "agent-beta",
      "merger"
    ]);
    expect(block!.workflow!.agents.every((agent) => agent.state === "done")).toBe(true);
  });

  test("the runId comes off the tool_use_result, which is its ONLY source", () => {
    // No task frame ever carries it, and the workflow-agent drill-in is keyed on
    // runId + agentId.
    expect(block!.subagent!.workflowRunId).toBe("wf_c0f60243-4f1");
    expect(model.tasksById.wxajrgc4u.workflowRunId).toBe("wf_c0f60243-4f1");
    expect(block!.subagent!.workflowName).toBe("alpha-beta-demo");
  });

  test("agent ids are present, so every row can be drilled into", () => {
    expect(block!.workflow!.agents.map((agent) => agent.agentId)).toEqual([
      "aec2c2f1b40b1481e",
      "a8ae08309fd862497",
      "a3591a4cc25d2d4ab"
    ]);
  });
});

describe("nested subagents attach to the nested block", () => {
  const model = replayLines(nestedFixture);

  test("the inner Agent card is a CHILD of the outer one", () => {
    const roots = model.turns.flatMap((turn) => turn.blocks).filter((b): b is ToolBlock => b.kind === "tool");
    const outer = roots.find((tool) => tool.name === "Agent");
    expect(outer).toBeDefined();
    const inner = outer!.children.find((child): child is ToolBlock => child.kind === "tool");
    expect(inner).toBeDefined();
    expect(inner!.toolUseId).toBe("toolu_016ZUDvuwcLJADkKKzais8k2");
  });

  test("task frames for the inner id reach the nested block, not the outer", () => {
    const outer = model.turns
      .flatMap((turn) => turn.blocks)
      .find((b): b is ToolBlock => b.kind === "tool" && b.name === "Agent")!;
    const inner = outer.children.find((child): child is ToolBlock => child.kind === "tool")!;
    expect(inner.subagent?.taskId).toBe("a9728442495aacb2c");
    expect(inner.subagent?.summary).toBe("51");
    expect(outer.subagent?.taskId).toBe("a273351272d38e227");
    expect(outer.subagent?.toolUses).toBe(1);
  });

  test("AgentOutput enriches the outer card with its model and metrics", () => {
    const outer = model.turns
      .flatMap((turn) => turn.blocks)
      .find((b): b is ToolBlock => b.kind === "tool" && b.name === "Agent")!;
    expect(outer.subagent?.model).toBe("claude-sonnet-5");
    expect(outer.subagent?.agentId).toBe("a273351272d38e227");
    expect(outer.subagent?.totalTokens).toBe(21050);
  });

  test("both tasks are recorded, and neither is in the strip", () => {
    // Neither agent was async, so `background_tasks_changed` never fires — and
    // the strip must stay empty even though two task_started frames arrived.
    expect(Object.keys(model.tasksById).sort()).toEqual([
      "a273351272d38e227",
      "a9728442495aacb2c"
    ]);
    expect(model.backgroundTasks).toEqual([]);
  });
});

describe("killed and stopped settle the launching block", () => {
  test("a stopped notification alone settles a still-running tool block", () => {
    // The CLI's kill sequence can end with ONLY `task_notification
    // {status: "stopped"}` — no completed/failed ever arrives — and a block
    // that settles only on those spins forever on work that is already dead.
    // An async agent's tool_result may never arrive, so the terminal task
    // frame is the ONLY settle its block gets — and the kill path's terminal
    // frame says `stopped`, not completed/failed.
    const index = createIndex();
    let model = createModel();
    const frames: ProtocolLine[] = [
      {
        type: "assistant",
        message: {
          id: "m_stop",
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: "toolu_stop_test",
              name: "Agent",
              input: { description: "long audit", prompt: "audit" }
            }
          ]
        },
        uuid: "stop-a1"
      } as ProtocolLine,
      {
        type: "system",
        subtype: "task_started",
        task_id: "t_stop_1",
        tool_use_id: "toolu_stop_test",
        task_type: "local_agent",
        description: "long audit",
        uuid: "stop-s1"
      } as ProtocolLine
    ];
    for (const line of frames) model = applyLine(model, index, line, Date.now());
    let block = tools(model).find((tool) => tool.toolUseId === "toolu_stop_test")!;
    expect(block.status).toBe("running");
    model = applyLine(
      model,
      index,
      {
        type: "system",
        subtype: "task_notification",
        task_id: "t_stop_1",
        status: "stopped",
        summary: "stopped by user",
        uuid: "stop-model-1"
      } as ProtocolLine,
      Date.now()
    );
    block = tools(model).find((tool) => tool.toolUseId === "toolu_stop_test")!;
    expect(block.status).toBe("aborted");
    expect(block.subagent?.status).toBe("stopped");
    expect(block.endedAtMs).toBeDefined();
  });
});

describe("a terminal status is a latch", () => {
  /** The workflow mid-flight, then killed by the user at frame 37. */
  function stoppedWorkflow() {
    const kill: ProtocolLine[] = [
      {
        type: "system",
        subtype: "task_updated",
        task_id: "wxajrgc4u",
        patch: { status: "killed", end_time: Date.now() },
        uuid: "latch-k1"
      } as ProtocolLine,
      {
        type: "system",
        subtype: "task_notification",
        task_id: "wxajrgc4u",
        status: "stopped",
        summary: "stopped by user",
        uuid: "latch-n1"
      } as ProtocolLine
    ];
    const index = createIndex();
    let model = createModel();
    for (const line of workflowFixture.slice(0, 37)) model = applyLine(model, index, line, Date.now());
    for (const line of kill) model = applyLine(model, index, line, Date.now());
    return { model, index };
  }

  test("progress arriving after the kill cannot walk the status back to running", () => {
    // stop_task answers `killed` while task_progress frames are already in
    // flight; without the latch they resurrect the record and the stopped
    // workflow then finishes and announces itself as a success.
    let { model, index } = stoppedWorkflow();
    expect(model.tasksById.wxajrgc4u.status).toBe("stopped");
    // Replay the rest of the probe's tail — progress, DONE states, completed
    // notification — exactly what the CLI replays after a kill lands.
    for (const line of workflowFixture.slice(37)) model = applyLine(model, index, line, Date.now());
    expect(model.tasksById.wxajrgc4u.status).toBe("stopped");
  });

  test("the frozen workflow snapshot keeps its partial totals", () => {
    let { model, index } = stoppedWorkflow();
    const before = model.tasksById.wxajrgc4u.workflow!;
    for (const line of workflowFixture.slice(37)) model = applyLine(model, index, line, Date.now());
    const after = model.tasksById.wxajrgc4u.workflow!;
    // The run the user killed at "1 of 3" must not quietly finish on screen.
    expect(after.totals.done).toBe(before.totals.done);
    expect(after.totals.done).toBeLessThan(after.totals.agents);
    const block = tools(model).find((tool) => tool.name === "Workflow")!;
    expect(block.subagent?.status).toBe("stopped");
    expect(block.workflow?.totals.done).toBe(before.totals.done);
  });

  test("a late completed notification is not re-announced", () => {
    let { model, index } = stoppedWorkflow();
    const banners = model.banners.length;
    expect(model.banners[banners - 1].titleKey).toBe("supermux.harness.notice.workflowStopped");
    for (const line of workflowFixture.slice(37)) model = applyLine(model, index, line, Date.now());
    // One task, one announcement: the replayed `completed` notification for the
    // stopped workflow raises nothing new.
    expect(model.banners.length).toBe(banners);
  });

  test("killed → stopped still moves — two frames of one interruption", () => {
    const { model } = stoppedWorkflow();
    // The kill patch says `killed`; the notification refines it to `stopped`.
    expect(model.tasksById.wxajrgc4u.status).toBe("stopped");
  });
});

describe("a stopped task's duration is latched with its status", () => {
  /** The workflow killed mid-flight, exactly as `stop_task` answers. */
  function killed() {
    const index = createIndex();
    let model = createModel();
    for (const line of workflowFixture.slice(0, 37)) model = applyLine(model, index, line, Date.now());
    const kill: ProtocolLine[] = [
      {
        type: "system",
        subtype: "task_updated",
        task_id: "wxajrgc4u",
        patch: { status: "killed", end_time: 1786991423000 },
        uuid: "dur-k1"
      } as ProtocolLine,
      {
        type: "system",
        subtype: "task_notification",
        task_id: "wxajrgc4u",
        status: "stopped",
        summary: "stopped by user",
        usage: { total_tokens: 16572, tool_uses: 0, duration_ms: 2100 },
        uuid: "dur-n1"
      } as ProtocolLine
    ];
    for (const line of kill) model = applyLine(model, index, line, Date.now());
    return { model, index };
  }

  test('"Stopped after 2s" is not rewritten by late progress frames', () => {
    // The CLI keeps sending task_progress for a few seconds after a kill — its
    // own in-flight frames plus any it replays — and each carries a LARGER
    // usage.duration_ms. Read straight through, the card's header silently
    // walked from "Stopped after 2s" to 3s to 5s while the user watched. How
    // long the work ran is settled by the moment it stopped.
    let { model, index } = killed();
    const at = model.tasksById.wxajrgc4u;
    expect(at.status).toBe("stopped");
    expect(at.durationMs).toBe(2100);
    for (const line of workflowFixture.slice(37)) model = applyLine(model, index, line, Date.now());
    expect(model.tasksById.wxajrgc4u.durationMs).toBe(2100);
  });

  test("the token and tool tallies latch too, and so does the end time", () => {
    // Same frames, same reason: a stopped run must not keep accumulating the
    // numbers of work it was stopped before doing.
    let { model, index } = killed();
    const at = model.tasksById.wxajrgc4u;
    expect(at.totalTokens).toBe(16572);
    expect(at.endedAtMs).toBe(1786991423000);
    for (const line of workflowFixture.slice(37)) model = applyLine(model, index, line, Date.now());
    const after = model.tasksById.wxajrgc4u;
    expect(after.totalTokens).toBe(16572);
    expect(after.endedAtMs).toBe(1786991423000);
    // The launching card reads the same latched figures.
    const block = tools(model).find((tool) => tool.name === "Workflow")!;
    expect(block.subagent?.durationMs).toBe(2100);
  });

  test("a task that is still RUNNING keeps updating, as it must", () => {
    // The latch is scoped to a terminal status; a live task's numbers are still
    // news, and freezing those would break the live card entirely.
    const staged = replayThrough(workflowFixture, 35);
    const before = staged.current.tasksById.wxajrgc4u.durationMs;
    staged.push(35, 50);
    expect(staged.current.tasksById.wxajrgc4u.durationMs).toBeGreaterThan(before ?? 0);
  });
});

describe("one clock for one piece of work", () => {
  test("the card reads the TASK's start, which is what the strip reads", () => {
    // The card counted from `block.startedAtMs` (when the tool_use block was
    // built) and the strip row from the record's, so the same shell reported two
    // different elapsed figures a second or two apart, forever.
    const model = replayLines(shellsFixture);
    const bash = tools(model).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    const record = model.tasksById.bnopezzr7;
    expect(bash.subagent?.startedAtMs).toBe(record.startedAtMs);
  });

  test("a block with no task at all still has its own clock to fall back on", () => {
    const model = replayLines(shellsFixture);
    const foreground = tools(model).find(
      (tool) => tool.name === "Bash" && tool.subagent?.taskId === undefined
    )!;
    expect(workStartedAtMs(foreground)).toBe(foreground.startedAtMs);
  });
});

describe("a finished background task raises an inline notice", () => {
  test("the stopped shell's notification says it was STOPPED, not just its name", () => {
    // The task's own description ("Print six ticks…") is which task; the outcome
    // is the news, and a banner carrying only the description explains nothing
    // about why it appeared.
    const model = replayLines(shellsFixture);
    expect(model.banners.length).toBe(1);
    expect(model.banners[0].titleKey).toBe("supermux.harness.notice.taskStopped");
    expect(model.banners[0].title).toBe("Print six ticks with 4-second sleeps between each");
    expect(model.banners[0].severity).toBe("info");
  });

  test("the workflow's completion banner says WORKFLOW and names it", () => {
    // "Workflow finished — alpha-beta-demo": a workflow is announced as what it
    // is, by its name, not as a generic background task carrying its summary.
    const model = replayLines(workflowFixture);
    expect(model.banners.length).toBe(1);
    expect(model.banners[0].titleKey).toBe("supermux.harness.notice.workflowFinished");
    expect(model.banners[0].title).toBe("alpha-beta-demo");
  });

  test("a FOREGROUND task's notification raises nothing", () => {
    // The nested probe's two agents both send task_notification and neither is
    // backgrounded; their results are already on the cards the user is reading.
    const model = replayLines(nestedFixture);
    expect(model.banners).toEqual([]);
  });
});

describe("Ctrl+B targets the command that is actually blocking the turn", () => {
  test("a running foreground Bash is found", () => {
    const staged = replayThrough(bgFixture, 17);
    expect(runningForegroundBash(staged.current)).toBe("toolu_016i2VPvtvJzj3Vqxz3gpkZS");
  });

  test("a command already in the background is NOT a target", () => {
    // It is not holding the turn up, so moving it is meaningless — and it would
    // silently retarget the key away from whatever the user was waiting on.
    const staged = replayThrough(bgFixture, 24);
    expect(runningForegroundBash(staged.current)).toBeUndefined();
  });

  test("a run_in_background launch is never a target either", () => {
    const staged = replayThrough(shellsFixture, 26);
    expect(runningForegroundBash(staged.current)).toBeUndefined();
  });

  test("nothing running means nothing to move", () => {
    expect(runningForegroundBash(replayLines(shellsFixture))).toBeUndefined();
  });
});

describe("BashOutput enriches the launching card", () => {
  test("run_in_background carries its task id and the background flag", () => {
    const model = replayLines(shellsFixture);
    const bash = tools(model).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    expect(bash.subagent!.background).toBe(true);
    expect(bash.subagent!.backgroundedByUser).toBeFalsy();
    expect(bash.subagent!.status).toBe("stopped");
  });

  test("a ctrl+B move is distinguishable from a run_in_background launch", () => {
    const model = replayLines(bgFixture);
    const bash = tools(model).find((tool) => tool.subagent?.taskId === "b20r5l4dg")!;
    expect(bash.subagent!.backgroundedByUser).toBe(true);
    expect(bash.subagent!.background).toBe(true);
  });
});

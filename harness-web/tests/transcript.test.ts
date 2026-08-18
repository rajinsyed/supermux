import { describe, expect, test } from "bun:test";
import { fixtures, richSession } from "../src/dev/fixtures";
import { permissionCompletion, permissionResolution } from "../src/dev/fixtures/permission";
import { questionResolution } from "../src/dev/fixtures/question";
import { planApproval } from "../src/dev/fixtures/plan";
import { resumeHistory } from "../src/dev/fixtures/resume";
import { applyLine, applyLocalAction, createIndex, createModel, replayLines } from "../src/model/transcript";
import type { Block, ToolBlock, TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";

function walk(model: TranscriptModel): Block[] {
  const out: Block[] = [];
  const visit = (blocks: Block[]) => {
    for (const block of blocks) {
      out.push(block);
      if (block.kind === "tool") visit(block.children);
    }
  };
  for (const turn of model.turns) visit(turn.blocks);
  return out;
}

function tools(model: TranscriptModel): ToolBlock[] {
  return walk(model).filter((b): b is ToolBlock => b.kind === "tool");
}

function replayAll(...groups: ProtocolLine[][]): TranscriptModel {
  const index = createIndex();
  let model = createModel();
  for (const group of groups) {
    for (const line of group) model = applyLine(model, index, line, Date.now());
  }
  return model;
}

describe("rich-session.jsonl replay", () => {
  const model = replayLines(richSession);

  test("parses the whole fixture", () => {
    expect(richSession.length).toBe(202);
  });

  test("reconstructs session meta from init", () => {
    expect(model.session.sessionId).toBe("68416c98-8a8e-47ab-9e5c-ddbb9604bcbe");
    expect(model.session.cwd).toBe("/private/tmp/harness-probe");
    expect(model.session.model).toBe("claude-sonnet-5");
    expect(model.session.cliVersion).toBe("2.1.233");
    expect(model.session.capabilities).toContain("interrupt_receipt_v1");
  });

  test("produces one turn per result", () => {
    expect(model.turns.length).toBe(3);
    expect(model.turns.every((t) => t.state === "complete")).toBe(true);
    expect(model.usage.turns).toBe(3);
  });

  test("merges every tool_use into a single card with its result", () => {
    const all = tools(model);
    const names = all.map((t) => t.name).sort();
    expect(names).toEqual(
      ["Agent", "Bash", "Bash", "Bash", "Edit", "Edit", "Read", "ToolSearch", "Write"].sort()
    );
    const withResults = all.filter((t) => t.resultText !== undefined || t.structured !== undefined);
    expect(withResults.length).toBe(all.length);
    expect(all.every((t) => t.status === "success" || t.status === "error")).toBe(true);
  });

  test("never duplicates a tool card despite the assistant/content_block_stop ordering quirk", () => {
    const ids = tools(model).map((t) => t.toolUseId);
    expect(new Set(ids).size).toBe(ids.length);
  });

  test("captures thinking blocks including empty ones", () => {
    const thinking = walk(model).filter((b) => b.kind === "thinking");
    expect(thinking.length).toBeGreaterThanOrEqual(4);
    expect(thinking.every((b) => b.kind === "thinking" && !b.streaming)).toBe(true);
  });

  test("nests the subagent Bash call under its Task card", () => {
    const task = tools(model).find((t) => t.name === "Agent");
    expect(task).toBeDefined();
    const child = task!.children.find((c) => c.kind === "tool") as ToolBlock | undefined;
    expect(child?.name).toBe("Bash");
    expect(task!.subagent?.subagentType).toBe("Explore");
    expect(task!.subagent?.status).toBe("completed");
    expect(task!.subagent?.summary).toContain("1 .py file");
  });

  test("accumulates cost and token usage", () => {
    expect(model.usage.costUsd).toBeGreaterThan(0.2);
    expect(model.usage.outputTokens).toBeGreaterThan(1000);
    expect(model.usage.thinkingTokens).toBeGreaterThan(0);
  });

  test("header cost is the session total and each turn footer is that turn's delta", () => {
    // The three results carry total_cost_usd 0.2286081 / 0.32379915 / 0.3585183.
    // Each equals its own cumulative modelUsage["claude-sonnet-5"].costUSD (whose
    // token counts also accumulate: cacheRead 143802 → 244263 → 331016), so
    // total_cost_usd is the CLI's running SESSION total, not the per-turn spend.
    expect(model.usage.costUsd).toBeCloseTo(0.3585183, 7);
    const totals = model.turns.map((turn) => turn.result?.totalCostUsd);
    expect(totals).toEqual([0.2286081, 0.32379915000000004, 0.3585183]);

    const deltas = model.turns.map((turn) => turn.result?.costDeltaUsd);
    expect(deltas[0]).toBeCloseTo(0.2286081, 7);
    expect(deltas[1]).toBeCloseTo(0.09519105, 7);
    expect(deltas[2]).toBeCloseTo(0.03471915, 7);
    // The deltas must reconstruct the header total exactly.
    expect(deltas.reduce((sum, d) => sum! + d!, 0)).toBeCloseTo(model.usage.costUsd, 7);
  });

  test("a result that reports a lower running total never walks the header backwards", () => {
    const index = createIndex();
    let m = createModel();
    const result = (cost: number, uuid: string): ProtocolLine =>
      ({
        type: "result",
        subtype: "success",
        is_error: false,
        result: "ok",
        duration_ms: 100,
        num_turns: 1,
        total_cost_usd: cost,
        uuid
      }) as ProtocolLine;
    const user = (uuid: string): ProtocolLine =>
      ({ type: "user", message: { role: "user", content: "go" }, uuid }) as ProtocolLine;
    m = applyLine(m, index, user("u1"), 1);
    m = applyLine(m, index, result(0.5, "r1"), 1);
    m = applyLine(m, index, user("u2"), 2);
    m = applyLine(m, index, result(0.2, "r2"), 2);
    expect(m.usage.costUsd).toBeCloseTo(0.5, 7);
    expect(m.turns[m.turns.length - 1].result?.costDeltaUsd).toBe(0);
  });

  test("renders Edit results from structuredPatch", () => {
    const edits = tools(model).filter((t) => t.name === "Edit");
    expect(edits.length).toBe(2);
    for (const edit of edits) {
      const patch = edit.structured?.structuredPatch as unknown[];
      expect(Array.isArray(patch)).toBe(true);
      expect(patch.length).toBeGreaterThan(0);
    }
  });

  test("no block leaks a streaming flag after replay", () => {
    const streaming = walk(model).filter((b) => "streaming" in b && b.streaming);
    expect(streaming.length).toBe(0);
  });
});

describe("permission fixture", () => {
  test("surfaces a pending Bash permission with its always-allow rule", () => {
    const model = replayLines(fixtures.permission);
    expect(model.pending.length).toBe(1);
    const pending = model.pending[0];
    expect(pending.kind).toBe("permission");
    expect(pending.request.tool_name).toBe("Bash");
    const suggestion = pending.request.permission_suggestions?.[0] as {
      type: string;
      rules: Array<{ ruleContent?: string }>;
    };
    expect(suggestion.type).toBe("addRules");
    expect(suggestion.rules[0].ruleContent).toBe("bun run db:migrate:*");
    expect(model.activity.sessionState).toBe("requires_action");
  });

  test("resolving the round trip runs the tool and closes the turn", () => {
    const model = replayAll(fixtures.permission, permissionResolution, permissionCompletion);
    const all = tools(model);
    const bash = all.find((t) => t.name === "Bash");
    expect(bash?.status).toBe("success");
    expect(bash?.structured?.stdout).toContain("migrations complete");
    const edit = all.find((t) => t.name === "Edit");
    expect(edit?.status).toBe("success");
    expect((edit?.structured?.structuredPatch as unknown[]).length).toBe(2);
    expect(model.turns[0].state).toBe("complete");
  });

  test("an Edit permission carries both an addRules and a setMode suggestion", () => {
    const model = replayAll(fixtures.permission, permissionResolution);
    const editPending = model.pending.find((p) => p.request.tool_name === "Edit");
    expect(editPending).toBeDefined();
    const kinds = (editPending!.request.permission_suggestions ?? []).map((s) => s.type);
    expect(kinds).toEqual(["addRules", "setMode"]);
  });
});

describe("question fixture", () => {
  test("classifies AskUserQuestion as a question with single and multi select", () => {
    const model = replayLines(fixtures.question);
    expect(model.pending.length).toBe(1);
    expect(model.pending[0].kind).toBe("question");
    const questions = model.pending[0].request.input.questions as Array<{ multiSelect: boolean }>;
    expect(questions.length).toBe(2);
    expect(questions[0].multiSelect).toBe(false);
    expect(questions[1].multiSelect).toBe(true);
  });

  test("answering clears the pending card and continues the turn", () => {
    const model = replayAll(fixtures.question, questionResolution);
    expect(model.pending.length).toBe(0);
    expect(model.turns[0].state).toBe("complete");
  });

  test("single-question variant has exactly one question", () => {
    const model = replayLines(fixtures.questionMulti);
    const questions = model.pending[0].request.input.questions as unknown[];
    expect(questions.length).toBe(1);
  });
});

describe("plan fixture", () => {
  test("ExitPlanMode is classified as a plan and carries markdown", () => {
    const model = replayLines(fixtures.plan);
    expect(model.pending.length).toBe(1);
    expect(model.pending[0].kind).toBe("plan");
    const plan = model.pending[0].request.input.plan as string;
    expect(plan).toContain("## Move terminal search into the portal layer");
    expect(model.session.permissionMode).toBe("plan");
  });

  test("approving the plan resolves the pending card", () => {
    const model = replayAll(fixtures.plan, planApproval);
    expect(model.pending.length).toBe(0);
    expect(model.turns[0].state).toBe("complete");
  });
});

describe("interrupt fixture", () => {
  const model = replayLines(fixtures.interrupt);

  test("marks the aborted turn and its partial text", () => {
    expect(model.turns.length).toBe(2);
    expect(model.turns[0].state).toBe("aborted");
    expect(model.turns[0].result?.terminalReason).toBe("aborted_streaming");
    const partial = model.turns[0].blocks.find((b) => b.kind === "text" && b.aborted);
    expect(partial).toBeDefined();
  });

  test("the process stays usable for the next turn", () => {
    expect(model.turns[1].state).toBe("complete");
    expect(model.activity.sessionState).toBe("idle");
  });
});

describe("errors fixture", () => {
  const model = replayLines(fixtures.errors);

  test("tints a failed Bash result red even without is_error", () => {
    const bash = tools(model).find((t) => t.name === "Bash");
    expect(bash?.status).toBe("error");
  });

  test("sniffs ENOENT in a Read failure", () => {
    const read = tools(model).find((t) => t.name === "Read");
    expect(read?.status).toBe("error");
  });

  test("raises an api_retry banner", () => {
    const retry = model.banners.find((b) => b.retry !== undefined);
    expect(retry?.retry?.attempt).toBe(1);
    expect(retry?.retry?.maxRetries).toBe(3);
  });

  test("renders a rate-limit assistant error as a failed turn", () => {
    const last = model.turns[model.turns.length - 1];
    expect(last.state).toBe("error");
    expect(last.errorText).toContain("usage limit");
  });
});

describe("compact fixture", () => {
  const model = replayLines(fixtures.compact);

  test("emits a compact divider carrying pre_tokens", () => {
    const divider = walk(model).find((b) => b.kind === "divider");
    expect(divider).toBeDefined();
    expect(divider!.kind === "divider" && divider!.preTokens).toBe(148320);
    expect(divider!.kind === "divider" && divider!.trigger).toBe("manual");
  });

  test("keeps turns on both sides of the boundary", () => {
    expect(model.turns.length).toBeGreaterThanOrEqual(3);
  });
});

describe("subagents fixture", () => {
  const model = replayLines(fixtures.subagents);

  test("groups two Task cards with lifecycle metadata", () => {
    const tasks = tools(model).filter((t) => t.name === "Task");
    expect(tasks.length).toBe(2);
    expect(tasks[0].subagent?.status).toBe("completed");
    expect(tasks[0].subagent?.totalTokens).toBe(21806);
    expect(tasks[1].subagent?.summary).toContain("6 supermux.* keys");
  });

  test("nests subagent tool calls under the parent Task", () => {
    const task = tools(model).find((t) => t.subagent?.subagentType === "Explore");
    expect(task!.children.some((c) => c.kind === "tool" && c.name === "Grep")).toBe(true);
  });

  /**
   * Round 4 moved the agent's own words OUT of the inline card. They used to be
   * pasted in as anonymous `notice` blocks, which is why the inline card had to
   * grow into a full nested transcript; now they build the agent's THREAD, the
   * inline surface is a one-line row, and the conversation is read in the agent
   * view. The same frames, folded once each — not dropped.
   */
  test("subagent text builds the agent's thread rather than an inline notice", () => {
    const task = tools(model).find((t) => t.subagent?.subagentType === "Explore")!;
    expect(task.children.some((c) => c.kind === "notice")).toBe(false);
    const thread = model.agentThreads[task.toolUseId];
    expect(thread).toBeDefined();
    expect(thread.blocks.some((b) => b.kind === "userText")).toBe(true);
  });

  test("tracks background tasks separately", () => {
    expect(model.backgroundTasks.length).toBe(1);
    expect(model.backgroundTasks[0].taskId).toBe("task_b1");
  });
});

describe("todos fixture", () => {
  const model = replayLines(fixtures.todos);

  test("keeps the latest todo list", () => {
    expect(model.todos.length).toBe(7);
    expect(model.todos.filter((t) => t.status === "completed").length).toBe(3);
    expect(model.todos.filter((t) => t.status === "in_progress").length).toBe(1);
  });
});

describe("thinking fixture", () => {
  const model = replayLines(fixtures.thinking);

  test("captures a long thought and an empty redacted one", () => {
    const thoughts = walk(model).filter((b) => b.kind === "thinking");
    expect(thoughts.length).toBe(2);
    expect(thoughts[0].kind === "thinking" && thoughts[0].text.length).toBeGreaterThan(400);
    expect(thoughts[1].kind === "thinking" && thoughts[1].text).toBe("");
    expect(thoughts[1].kind === "thinking" && thoughts[1].tokens).toBe(640);
  });
});

describe("longform fixture", () => {
  const model = replayLines(fixtures.longform);

  test("builds a session with hundreds of blocks", () => {
    expect(model.turns.length).toBe(24);
    expect(walk(model).length).toBeGreaterThan(400);
  });

  test("every turn settles", () => {
    expect(model.turns.every((t) => t.state === "complete")).toBe(true);
  });
});

describe("resume fixture", () => {
  test("history replay reconstructs prior turns before the live one", () => {
    const history = replayLines(resumeHistory);
    expect(history.turns.length).toBe(2);
    expect(history.turns.every((t) => t.state === "complete")).toBe(true);
    const full = replayLines(fixtures.resume);
    expect(full.turns.length).toBe(3);
  });
});

/**
 * The real CLI never emits `system/session_state_changed`: `grep -c` returns 0 on
 * the checked-in 202-line trace AND on all five live probe logs, which carry only
 * init / status / thinking_tokens / permission_denied / can_use_tool. Treating
 * that frame as the sole writer of `sessionState` latched the pane to "running"
 * after the first turn — permanent "Claude is thinking…", a Stop button, a
 * "will be queued" composer, and a queue that never drained. The `result` frame
 * is the only end-of-turn signal that actually arrives, so it settles the flag.
 */
describe("idleness without a session_state_changed frame", () => {
  const bareTurn: ProtocolLine[] = [
    { type: "system", subtype: "session_state_changed", state: "running", uuid: "s1" } as ProtocolLine,
    { type: "user", message: { role: "user", content: "audit the reducer" }, uuid: "u1" } as ProtocolLine,
    {
      type: "assistant",
      message: { id: "m1", role: "assistant", content: [{ type: "text", text: "Done." }] },
      uuid: "a1"
    } as ProtocolLine,
    {
      type: "result",
      subtype: "success",
      is_error: false,
      result: "Done.",
      duration_ms: 900,
      uuid: "r1"
    } as ProtocolLine
  ];

  test("the fixtures no longer hand-write the frame the CLI never sends", async () => {
    const root = new URL("../src/dev/fixtures/", import.meta.url).pathname;
    const files = Array.from(new Bun.Glob("*.ts").scanSync({ cwd: root, absolute: true }));
    const source = (await Promise.all(files.map((path) => Bun.file(path).text()))).join("\n");
    expect(source).not.toContain('sessionState("idle")');
    // The real capture is the reference for what the CLI does emit.
    const trace = await Bun.file(
      new URL("../src/dev/fixtures/rich-session.jsonl", import.meta.url).pathname
    ).text();
    expect(trace).not.toContain("session_state_changed");
  });

  test("a bare result settles the session to idle", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of bareTurn) model = applyLine(model, index, line, 1000);
    expect(model.turns[0].state).toBe("complete");
    expect(model.activity.sessionState).toBe("idle");
    expect(model.activity.status).toBeNull();
  });

  test("the next message sends immediately instead of queueing forever", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of bareTurn) model = applyLine(model, index, line, 1000);
    model = applyLocalAction(
      model,
      index,
      { kind: "localSend", uuid: "next-1", text: "are you there", atMs: 1100 },
      1100
    );
    expect(model.queued.length).toBe(0);
    expect(model.turns.length).toBe(2);
    expect(model.turns[1].userText).toBe("are you there");
  });

  test("an interrupt result also releases the pane", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of fixtures.queue) model = applyLine(model, index, line, 1000);
    expect(model.activity.sessionState).toBe("running");
    model = applyLine(
      model,
      index,
      {
        type: "result",
        subtype: "error_during_execution",
        is_error: true,
        result: "Interrupted by user",
        terminal_reason: "aborted_streaming",
        uuid: "r-int"
      } as ProtocolLine,
      1200
    );
    expect(model.turns[0].state).toBe("aborted");
    expect(model.activity.sessionState).toBe("idle");
  });

  test("a mid-turn permission still holds the pane in requires_action", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of fixtures.permission) model = applyLine(model, index, line, 1000);
    expect(model.pending.length).toBe(1);
    model = applyLine(model, index, { type: "result", subtype: "success", uuid: "r-mid" } as ProtocolLine, 1100);
    // The turn ended but the user still owes an answer; going idle here would
    // send the next message into a process that is waiting on a decision.
    expect(model.activity.sessionState).toBe("requires_action");
  });

  test("an explicit session_state_changed still wins for CLIs that send one", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of bareTurn) model = applyLine(model, index, line, 1000);
    model = applyLine(
      model,
      index,
      { type: "system", subtype: "session_state_changed", state: "running", uuid: "s2" } as ProtocolLine,
      1100
    );
    expect(model.activity.sessionState).toBe("running");
  });

  test("every scenario ends idle once its last result lands", () => {
    const stuck: string[] = [];
    for (const [name, lines] of Object.entries(fixtures)) {
      const model = replayLines(lines as ProtocolLine[]);
      const settled = model.turns.length > 0 && model.turns.every((t) => t.state !== "streaming");
      if (!settled || model.pending.length > 0) continue;
      if (model.activity.sessionState !== "idle") stuck.push(`${name}=${model.activity.sessionState}`);
    }
    expect(stuck).toEqual([]);
  });
});

describe("local actions", () => {
  test("a send while running becomes a queued chip and can be cancelled", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of fixtures.queue) model = applyLine(model, index, line, 1000);
    expect(model.activity.sessionState).toBe("running");
    model = applyLocalAction(model, index, {
      kind: "localSend",
      uuid: "queued-1",
      text: "Also check the iOS side.",
      atMs: 1100
    }, 1100);
    model = applyLocalAction(model, index, {
      kind: "localSend",
      uuid: "queued-2",
      text: "And add a round-trip test.",
      atMs: 1200
    }, 1200);
    expect(model.queued.length).toBe(2);
    model = applyLocalAction(model, index, { kind: "cancelQueued", uuid: "queued-1" }, 1300);
    expect(model.queued.map((q) => q.uuid)).toEqual(["queued-2"]);
  });

  test("a send while idle starts a turn immediately", () => {
    const index = createIndex();
    let model = createModel();
    model = applyLocalAction(model, index, {
      kind: "localSend",
      uuid: "send-1",
      text: "Explain the reducer",
      atMs: 10
    }, 10);
    expect(model.queued.length).toBe(0);
    expect(model.turns.length).toBe(1);
    expect(model.turns[0].userText).toBe("Explain the reducer");
    expect(model.session.title).toBe("Explain the reducer");
  });

  test("conversation reset remounts the transcript and bumps the generation", () => {
    const index = createIndex();
    let model = replayLines(fixtures.todos);
    model = applyLocalAction(model, index, { kind: "reset" }, 1);
    expect(model.turns.length).toBe(0);
    expect(model.todos.length).toBe(0);
    expect(model.generation).toBe(1);
  });

  test("supersedes evicts retracted assistant blocks", () => {
    const index = createIndex();
    let model = createModel();
    const lines: ProtocolLine[] = [
      { type: "user", message: { role: "user", content: "hi" }, uuid: "u1" } as ProtocolLine,
      {
        type: "assistant",
        message: { id: "m1", role: "assistant", content: [{ type: "text", text: "first draft" }] },
        uuid: "a1"
      } as ProtocolLine,
      {
        type: "assistant",
        message: { id: "m2", role: "assistant", content: [{ type: "text", text: "final answer" }] },
        uuid: "a2",
        supersedes: ["a1"]
      } as ProtocolLine
    ];
    for (const line of lines) model = applyLine(model, index, line, 5);
    const texts = walk(model).filter((b) => b.kind === "text");
    expect(texts.length).toBe(1);
    expect(texts[0].kind === "text" && texts[0].text).toBe("final answer");
  });

  test("an answered question stays in the transcript as a Q&A record", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of fixtures.question) model = applyLine(model, index, line, 1000);
    const pending = model.pending[0];
    expect(pending.kind).toBe("question");
    const questions = pending.request.input.questions;

    model = applyLocalAction(
      model,
      index,
      {
        kind: "permissionResolved",
        requestId: pending.requestId,
        behavior: "allow",
        updatedInput: {
          questions,
          answers: {
            "Which authentication provider should the dashboard use?": "Stack Auth",
            "Which surfaces need to be gated behind login on day one?": "Billing, Team settings"
          }
        } as never
      },
      1100
    );

    // Before the fix the exchange vanished completely: the only trace was the
    // model happening to restate the choice in prose.
    const asked = tools(model).find((t) => t.name === "AskUserQuestion");
    expect(asked).toBeDefined();
    expect(asked!.status).toBe("success");
    expect(asked!.toolUseId).toBe(pending.request.tool_use_id!);
    const recorded = asked!.input.answers as Record<string, string>;
    expect(recorded["Which authentication provider should the dashboard use?"]).toBe("Stack Auth");
    expect(Array.isArray(asked!.input.questions)).toBe(true);
  });

  test("a dismissed question is recorded as denied, keeping the question text", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of fixtures.question) model = applyLine(model, index, line, 1000);
    model = applyLocalAction(
      model,
      index,
      { kind: "permissionResolved", requestId: model.pending[0].requestId, behavior: "deny" },
      1100
    );
    const asked = tools(model).find((t) => t.name === "AskUserQuestion");
    expect(asked?.status).toBe("denied");
    expect(Array.isArray(asked?.input.questions)).toBe(true);
  });

  test("resolving an ordinary tool permission adds no duplicate card", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of fixtures.permission) model = applyLine(model, index, line, 1000);
    const before = tools(model).length;
    model = applyLocalAction(
      model,
      index,
      { kind: "permissionResolved", requestId: model.pending[0].requestId, behavior: "allow" },
      1100
    );
    // The Bash call already has its own streamed card; a second one would print
    // the command twice.
    expect(tools(model).length).toBe(before);
  });

  test("a run exit closes any open turn", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of fixtures.queue) model = applyLine(model, index, line, 1);
    expect(model.turns[0].state).toBe("streaming");
    const { applyEvent } = require("../src/model/transcript") as typeof import("../src/model/transcript");
    model = applyEvent(model, index, { kind: "runExited", runId: "r1", status: 1, error: "spawn failed" }, 2);
    expect(model.turns[0].state).toBe("error");
    expect(model.runPhase).toBe("exited");
    expect(model.exitError).toBe("spawn failed");
  });
});

describe("session title and history truncation", () => {
  test("a sessionTitle event names the session and later retitles win", () => {
    const index = createIndex();
    let model = createModel();
    const { applyEvent } = require("../src/model/transcript") as typeof import("../src/model/transcript");
    model = applyEvent(model, index, { kind: "sessionTitle", title: "Audit snapshot restore" }, 1);
    expect(model.session.title).toBe("Audit snapshot restore");
    // The CLI retitles as the topic evolves; the native side gates on renames,
    // so the reducer must not freeze the first title it sees.
    model = applyEvent(model, index, { kind: "sessionTitle", title: "Fix restore drift" }, 2);
    expect(model.session.title).toBe("Fix restore drift");
  });

  test("historyTruncated survives replayed lines and clears on reset", () => {
    const index = createIndex();
    let model = createModel();
    model = applyLocalAction(model, index, { kind: "historyTruncated" }, 1);
    for (const line of fixtures.queue) model = applyLine(model, index, line, 2);
    expect(model.historyTruncated).toBe(true);
    model = applyLocalAction(model, index, { kind: "reset" }, 3);
    expect(model.historyTruncated).toBeUndefined();
  });
});

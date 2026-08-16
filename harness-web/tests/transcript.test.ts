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

  test("nests subagent tool calls and text under the parent Task", () => {
    const task = tools(model).find((t) => t.subagent?.subagentType === "Explore");
    expect(task!.children.some((c) => c.kind === "tool" && c.name === "Grep")).toBe(true);
    expect(task!.children.some((c) => c.kind === "notice")).toBe(true);
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

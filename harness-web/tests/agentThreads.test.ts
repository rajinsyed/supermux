import { describe, expect, test } from "bun:test";
import {
  FWD_INNER_TOOL_USE_ID,
  FWD_OUTER_TOOL_USE_ID,
  fwdNestedFixture,
  RELAY_AGENT_TOOL_USE_ID,
  relayFixture
} from "../src/dev/fixtures/round4";
import { shellsFixture, workflowFixture } from "../src/dev/fixtures/round3";
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

function turnTools(model: TranscriptModel) {
  return model.turns.flatMap((turn) => turn.blocks).filter((block) => block.kind === "tool");
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

describe("agent thread inline images", () => {
  test("keeps an image result in the agent conversation that produced it", () => {
    const rootToolUseId = "toolu_image_agent";
    const readToolUseId = "toolu_image_read";
    const dataBase64 = "iVBORw0KGgo=";
    const model = replayLines([
      {
        type: "user",
        message: { role: "user", content: "Delegate image inspection" },
        uuid: "agent-image-user"
      } as ProtocolLine,
      {
        type: "assistant",
        message: {
          id: "agent-image-spawn",
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: rootToolUseId,
              name: "Agent",
              input: { description: "Inspect image", prompt: "Read the image" }
            }
          ]
        },
        uuid: "agent-image-spawn-frame"
      } as ProtocolLine,
      {
        type: "user",
        message: { role: "user", content: [{ type: "text", text: "Read the image" }] },
        parent_tool_use_id: rootToolUseId,
        uuid: "agent-image-prompt"
      } as ProtocolLine,
      {
        type: "assistant",
        message: {
          id: "agent-image-read",
          role: "assistant",
          content: [
            { type: "tool_use", id: readToolUseId, name: "Read", input: { file_path: "image.png" } }
          ]
        },
        parent_tool_use_id: rootToolUseId,
        uuid: "agent-image-read-frame"
      } as ProtocolLine,
      {
        type: "user",
        message: {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: readToolUseId,
              content: [
                {
                  type: "image",
                  source: { type: "base64", media_type: "image/png", data: dataBase64 }
                }
              ]
            }
          ]
        },
        parent_tool_use_id: rootToolUseId,
        uuid: "agent-image-result"
      } as ProtocolLine
    ]);

    const blocks = model.agentThreads[rootToolUseId].blocks;
    expect(blocks.map((block) => block.kind)).toEqual(["userText", "tool", "image"]);
    expect(blocks[2]).toMatchObject({ kind: "image", mediaType: "image/png", dataBase64 });
  });
});

/**
 * The dock is a LIVE SET.
 *
 * Round 4 kept a settled row on the dock, dimmed, for the session. Dogfood
 * verdict: "done or stopped agents shouldnt show anymore and should be cleared.
 * only working agents should show. same for workflows." So membership is now
 * exactly "is this still running", and these assert the rows appear and then
 * GO — for agents, workflows and shells alike.
 */
describe("failed agent attempts and retries", () => {
  const description = "Map backend integrations";
  const failedToolUseId = "call_backend_invalid_model";
  const retryToolUseId = "call_backend_retry";
  const failedLaunch: ProtocolLine[] = [
    {
      type: "assistant",
      message: {
        id: "msg_backend_failed",
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: failedToolUseId,
            name: "Agent",
            input: {
              description,
              prompt: "Map the backend",
              subagent_type: "Explore",
              model: "sol",
              run_in_background: true
            }
          }
        ]
      },
      uuid: "assistant-backend-failed"
    } as ProtocolLine,
    {
      type: "user",
      message: {
        role: "user",
        content: [
          {
            type: "tool_result",
            tool_use_id: failedToolUseId,
            is_error: true,
            content:
              '<tool_use_error>InputValidationError: Invalid option: expected one of "sonnet"|"opus"|"haiku"|"fable"</tool_use_error>'
          }
        ]
      },
      uuid: "result-backend-failed"
    } as ProtocolLine
  ];
  const successfulRetry: ProtocolLine[] = [
    {
      type: "assistant",
      message: {
        id: "msg_backend_retry",
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: retryToolUseId,
            name: "Agent",
            input: {
              description,
              prompt: "Map the backend",
              subagent_type: "Explore",
              run_in_background: true
            }
          }
        ]
      },
      uuid: "assistant-backend-retry"
    } as ProtocolLine,
    {
      type: "user",
      message: {
        role: "user",
        content: [
          {
            type: "tool_result",
            tool_use_id: retryToolUseId,
            content: "Async agent launched successfully."
          }
        ]
      },
      tool_use_result: {
        status: "async_launched",
        agentId: "agent_backend_retry",
        resolvedModel: "claude-opus-5"
      },
      uuid: "result-backend-retry"
    } as ProtocolLine,
    {
      type: "system",
      subtype: "task_started",
      task_id: "agent_backend_retry",
      tool_use_id: retryToolUseId,
      task_type: "local_agent",
      description,
      prompt: "Map the backend",
      status: "running",
      uuid: "task-backend-started"
    } as ProtocolLine,
    {
      type: "system",
      subtype: "task_notification",
      task_id: "agent_backend_retry",
      status: "completed",
      summary: `Agent "${description}" finished`,
      uuid: "task-backend-completed"
    } as ProtocolLine
  ];

  test("an is_error tool result genuinely fails both the inline attempt and its thread", () => {
    const model = replayLines(failedLaunch);
    const block = turnTools(model)[0];
    expect(block.status).toBe("error");
    expect(block.subagent?.status).toBe("failed");
    expect(model.agentThreads[failedToolUseId].status).toBe("failed");
    expect(block.supersededByToolUseId).toBeUndefined();
    expect(model.agentThreads[failedToolUseId].supersededByToolUseId).toBeUndefined();
  });

  test("a later successful retry with the same description supersedes the failed sibling", () => {
    const model = replayLines([...failedLaunch, ...successfulRetry]);
    const [failed, retry] = turnTools(model);
    expect(retry.subagent?.status).toBe("completed");
    expect(failed.supersededByToolUseId).toBe(retryToolUseId);
    expect(model.agentThreads[failedToolUseId].supersededByToolUseId).toBe(retryToolUseId);
  });

  test("a nested retry is superseded in both the inline tree and parent drill-in", () => {
    const parentToolUseId = "call_parent_agent";
    const parentLaunch = {
      type: "assistant",
      message: {
        id: "msg_parent_agent",
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: parentToolUseId,
            name: "Agent",
            input: { description: "Coordinate audit", prompt: "Delegate the backend map" }
          }
        ]
      },
      uuid: "assistant-parent-agent"
    } as ProtocolLine;
    const nestedAttempts = [...failedLaunch, ...successfulRetry].map((line) =>
      line.type === "assistant" || line.type === "user"
        ? ({ ...line, parent_tool_use_id: parentToolUseId } as ProtocolLine)
        : line
    );
    const model = replayLines([parentLaunch, ...nestedAttempts]);
    const parentBlock = turnTools(model)[0];
    const inlineFailed = parentBlock.children.find(
      (block) => block.kind === "tool" && block.toolUseId === failedToolUseId
    );
    const drillInFailed = model.agentThreads[parentToolUseId].blocks.find(
      (block) => block.kind === "tool" && block.toolUseId === failedToolUseId
    );

    expect(inlineFailed?.kind).toBe("tool");
    expect(inlineFailed?.kind === "tool" && inlineFailed.supersededByToolUseId).toBe(retryToolUseId);
    expect(drillInFailed?.kind).toBe("tool");
    expect(drillInFailed?.kind === "tool" && drillInFailed.supersededByToolUseId).toBe(
      retryToolUseId
    );
  });

  test("an interrupted tool result is stopped, not failed, even when the wire sets is_error", () => {
    const toolUseId = "call_interrupted_agent";
    const model = replayLines([
      {
        type: "assistant",
        message: {
          id: "msg_interrupted_agent",
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: toolUseId,
              name: "Agent",
              input: { description: "Long audit", prompt: "Audit until interrupted" }
            }
          ]
        },
        uuid: "assistant-interrupted-agent"
      } as ProtocolLine,
      {
        type: "user",
        message: {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: toolUseId,
              is_error: true,
              content: "Interrupted by user"
            }
          ]
        },
        tool_use_result: { interrupted: true },
        uuid: "result-interrupted-agent"
      } as ProtocolLine
    ]);
    const block = turnTools(model)[0];
    expect(block.status).toBe("aborted");
    expect(block.subagent?.status).toBe("stopped");
    expect(model.agentThreads[toolUseId].status).toBe("stopped");
  });

  test("a completed agent report may discuss an error without becoming a failed attempt", () => {
    const toolUseId = "call_successful_error_audit";
    const model = replayLines([
      {
        type: "assistant",
        message: {
          id: "msg_successful_error_audit",
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: toolUseId,
              name: "Agent",
              input: { description: "Audit release logs", prompt: "Inspect the logs" }
            }
          ]
        },
        uuid: "assistant-successful-error-audit"
      } as ProtocolLine,
      {
        type: "user",
        message: {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: toolUseId,
              content:
                "There is no local Release compile or link error: the build was interrupted before one was produced."
            }
          ]
        },
        tool_use_result: {
          status: "completed",
          agentId: "agent_successful_error_audit",
          resolvedModel: "claude-opus-5"
        },
        uuid: "result-successful-error-audit"
      } as ProtocolLine
    ]);
    const block = turnTools(model)[0];
    expect(block.status).toBe("success");
    expect(block.subagent?.status).toBe("completed");
    expect(model.agentThreads[toolUseId].status).toBe("completed");
  });
});

describe("the dock's rows", () => {
  test("main is first, then RUNNING agents in tree order with an indent per level", () => {
    const live = replayThrough(fwdNestedFixture, 40);
    expect(dockRows(live).map((row) => [row.kind, row.depth, row.label])).toEqual([
      ["main", 0, ""],
      ["agent", 1, "Outer relay"],
      ["agent", 2, "Inner counter"]
    ]);
  });

  test("a finished agent LOSES its row", () => {
    // The round-4 behaviour, inverted. A dock full of rows for work that ended
    // is a list the user has to read past to find the one thing still going,
    // and nothing ever cleared it.
    const model = replayLines(fwdNestedFixture);
    expect(model.agentThreads[FWD_OUTER_TOOL_USE_ID].status).toBe("completed");
    expect(dockRows(model).filter((row) => row.kind === "agent")).toEqual([]);
  });

  test("when everything has finished, only main is left — so the dock hides", () => {
    // `rows.length <= 1` is what AgentsDock renders nothing on, so an empty
    // dock is proven here rather than only in the DOM test.
    const model = replayLines(fwdNestedFixture);
    expect(dockRows(model).map((row) => row.kind)).toEqual(["main"]);
  });

  test("main STAYS when it goes idle — it is a place, not a task", () => {
    const model = replayLines(fwdNestedFixture);
    const main = dockRows(model)[0];
    expect(main.kind).toBe("main");
    expect(main.running).toBe(false);
    // And it never offers a Stop: there is no task behind it.
    expect(main.stopTaskId).toBeUndefined();
  });

  test("a live row carries the tallies its work has cost so far", () => {
    const live = replayThrough(fwdNestedFixture, 40);
    const outer = dockRows(live).find((row) => row.label === "Outer relay")!;
    expect(outer.running).toBe(true);
    expect(outer.startedAtMs).toBeDefined();
  });

  test("every non-main row on the dock is running, in every fixture", () => {
    // The invariant the whole item rests on: nothing terminal is ever docked.
    for (const fixture of [fwdNestedFixture, relayFixture]) {
      for (const cut of [20, 34, 40, fixture.length]) {
        for (const row of dockRows(replayThrough(fixture, cut))) {
          if (row.kind === "main") continue;
          expect(row.running).toBe(true);
          expect(["completed", "failed", "killed", "stopped"]).not.toContain(row.status ?? "");
        }
      }
    }
  });

  test("a live shell does not print its own description twice", () => {
    const live = replayThrough(relayFixture, 34);
    for (const row of dockRows(live)) {
      if (row.detail === undefined) continue;
      expect(row.detail).not.toBe(row.label);
    }
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
    // keeps that rule for shells on TOP of the running rule.
    const live = replayThrough(relayFixture, 34);
    const shells = dockRows(live).filter((row) => row.kind === "shell");
    for (const row of shells) {
      expect(live.tasksById[row.view.kind === "shell" ? row.view.taskId : ""].isBackgrounded).toBe(
        true
      );
    }
  });

  test("an agent never appears twice — once as a thread and once as a task row", () => {
    const live = replayThrough(relayFixture, 34);
    const rows = dockRows(live);
    const agentIds = rows.filter((row) => row.kind === "agent").map((row) => row.label);
    expect(new Set(agentIds).size).toBe(agentIds.length);
    // The relay probe's agent is a `local_agent` task AND a thread; only the
    // thread may draw it, or the dock lists one agent as two things.
    expect(rows.filter((row) => row.label === "Slow summarizer").length).toBe(1);
  });

  test("a child whose parent finished is PROMOTED, not left hanging on a guide", () => {
    // Depth is counted over VISIBLE ancestors. Without that the inner agent
    // would keep depth 2 and draw a `└` under a row that is no longer on the
    // dock — an indent pointing at nothing.
    let live = replayThrough(fwdNestedFixture, 40);
    expect(dockRows(live).map((row) => row.depth)).toEqual([0, 1, 2]);
    live = {
      ...live,
      agentThreads: {
        ...live.agentThreads,
        [FWD_OUTER_TOOL_USE_ID]: {
          ...live.agentThreads[FWD_OUTER_TOOL_USE_ID],
          status: "completed"
        }
      }
    };
    const rows = dockRows(live);
    expect(rows.map((row) => [row.kind, row.depth, row.label])).toEqual([
      ["main", 0, ""],
      ["agent", 1, "Inner counter"]
    ]);
  });

  test("a workflow row goes the moment the run is terminal", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of workflowFixture) model = applyLine(model, index, line, Date.now());
    expect(model.tasksById.wxajrgc4u.status).toBe("completed");
    expect(dockRows(model).filter((row) => row.kind === "workflow")).toEqual([]);
    // And it WAS there while it ran.
    const mid = replayThrough(workflowFixture, 30);
    expect(dockRows(mid).filter((row) => row.kind === "workflow").length).toBe(1);
  });

  test("a stopped shell row goes too, not just a completed one", () => {
    const mid = replayThrough(shellsFixture, 30);
    const running = dockRows(mid).filter((row) => row.kind === "shell");
    expect(running.length).toBeGreaterThan(0);
    const model = replayLines(shellsFixture);
    for (const row of dockRows(model)) {
      if (row.kind !== "shell") continue;
      const record = model.tasksById[row.view.kind === "shell" ? row.view.taskId : ""];
      expect(["completed", "failed", "killed", "stopped"]).not.toContain(record.status ?? "");
    }
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

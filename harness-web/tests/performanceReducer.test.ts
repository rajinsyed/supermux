import { describe, expect, test } from "bun:test";
import type { NativeEvent, ProtocolLine, StreamEventLine } from "../src/protocol/types";
import { HarnessStore } from "../src/model/store";
import {
  applyEvents,
  applyLine,
  applyLocalAction,
  createIndex,
  createModel
} from "../src/model/transcript";
import type { Block, ToolBlock, TranscriptModel } from "../src/model/types";
import {
  clearHighlightCache,
  highlightCacheStats,
  highlightToHtml
} from "../src/ui/highlight";

function protocol(line: ProtocolLine): NativeEvent {
  return { kind: "protocol", line };
}

function user(uuid: string, text: string): ProtocolLine {
  return {
    type: "user",
    uuid,
    message: { role: "user", content: text }
  } as ProtocolLine;
}

function result(uuid: string): ProtocolLine {
  return {
    type: "result",
    uuid,
    subtype: "success",
    is_error: false,
    result: "done"
  } as ProtocolLine;
}

function assistantTool(
  uuid: string,
  messageId: string,
  toolUseId: string,
  name: string,
  input: Record<string, unknown>
): ProtocolLine {
  return {
    type: "assistant",
    uuid,
    message: {
      id: messageId,
      role: "assistant",
      content: [{ type: "tool_use", id: toolUseId, name, input }]
    }
  } as ProtocolLine;
}

function streamLine(
  event: StreamEventLine["event"],
  uuid?: string,
  parentToolUseId?: string
): ProtocolLine {
  return {
    type: "stream_event",
    event,
    uuid,
    parent_tool_use_id: parentToolUseId
  } as ProtocolLine;
}

function toolBlocks(model: TranscriptModel): ToolBlock[] {
  const blocks: ToolBlock[] = [];
  const walk = (items: Block[]) => {
    for (const block of items) {
      if (block.kind !== "tool") continue;
      blocks.push(block);
      walk(block.children);
    }
  };
  for (const turn of model.turns) walk(turn.blocks);
  return blocks;
}

function startedPartialTool() {
  const index = createIndex();
  let model = createModel();
  model = applyEvents(
    model,
    index,
    [
      protocol(streamLine({ type: "message_start", message: { id: "message-main" } }, "main-start")),
      protocol(
        streamLine(
          {
            type: "content_block_start",
            index: 0,
            content_block: { type: "tool_use", id: "tool-main", name: "Bash", input: {} }
          },
          "main-block-start"
        )
      )
    ],
    1000
  );
  return { index, model };
}

describe("turn revisions are the row invalidation contract", () => {
  test("a local fold toggle notifies only after its turn revision advances", () => {
    const store = new HarnessStore();
    store.dispatch({ kind: "localSend", uuid: "turn-1", text: "hello", atMs: 1 });
    let calls = 0;
    const unsubscribe = store.subscribeTurn("turn-1", () => {
      calls += 1;
    });

    store.dispatch({ kind: "toggleFold", turnId: "turn-1", folded: true });

    unsubscribe();
    expect(calls).toBe(1);
    expect(store.getTurn("turn-1")?.revision).toBeGreaterThan(0);
  });
});

describe("partial tool JSON is reduced once per native batch and block", () => {
  test("many fragments produce one preview revision", () => {
    const seeded = startedPartialTool();
    const before = seeded.model.turns[0].revision;
    const fragments = ["{", '"command"', ":", '"echo ok"', ",", '"description"', ":", '"demo"', "}"];
    const events = fragments.map((partial_json, offset) =>
      protocol(
        streamLine(
          {
            type: "content_block_delta",
            index: 0,
            delta: { type: "input_json_delta", partial_json }
          },
          `fragment-${offset}`
        )
      )
    );

    const next = applyEvents(seeded.model, seeded.index, events, 1001);

    expect(next.turns[0].revision - before).toBe(1);
    expect(toolBlocks(next)[0].input).toEqual({ command: "echo ok", description: "demo" });
  });

  test("interleaved main and forwarded scopes never drop later fragments", () => {
    const seeded = startedPartialTool();
    const events: NativeEvent[] = [
      protocol(
        streamLine(
          {
            type: "content_block_delta",
            index: 0,
            delta: { type: "input_json_delta", partial_json: '{"command":"echo ' }
          },
          "main-fragment-one"
        )
      ),
      protocol(
        streamLine(
          { type: "message_start", message: { id: "message-forwarded" } },
          "forwarded-message-start",
          "agent-parent"
        )
      ),
      protocol(
        streamLine(
          {
            type: "content_block_start",
            index: 0,
            content_block: { type: "tool_use", id: "tool-forwarded", name: "Bash", input: {} }
          },
          "forwarded-block-start",
          "agent-parent"
        )
      ),
      protocol(
        streamLine(
          {
            type: "content_block_delta",
            index: 0,
            delta: { type: "input_json_delta", partial_json: '{"command":"pwd"}' }
          },
          "forwarded-fragment",
          "agent-parent"
        )
      ),
      protocol(
        streamLine(
          { type: "content_block_stop", index: 0 },
          "forwarded-block-stop",
          "agent-parent"
        )
      ),
      protocol(
        streamLine(
          {
            type: "content_block_delta",
            index: 0,
            delta: { type: "input_json_delta", partial_json: 'ok"}' }
          },
          "main-fragment-two"
        )
      ),
      protocol(streamLine({ type: "content_block_stop", index: 0 }, "main-block-stop")),
      protocol(streamLine({ type: "message_start", message: { id: "message-reused" } }, "reused-start")),
      protocol(
        streamLine(
          {
            type: "content_block_start",
            index: 0,
            content_block: { type: "tool_use", id: "tool-reused", name: "Bash", input: {} }
          },
          "reused-block-start"
        )
      ),
      protocol(
        streamLine(
          {
            type: "content_block_delta",
            index: 0,
            delta: { type: "input_json_delta", partial_json: '{"command":"date"}' }
          },
          "reused-fragment"
        )
      ),
      protocol(streamLine({ type: "content_block_stop", index: 0 }, "reused-stop"))
    ];

    const next = applyEvents(seeded.model, seeded.index, events, 1001);
    const byId = new Map(toolBlocks(next).map((block) => [block.toolUseId, block]));

    expect(byId.get("tool-main")?.input).toEqual({ command: "echo ok" });
    expect(byId.get("tool-forwarded")?.input).toEqual({ command: "pwd" });
    expect(byId.get("tool-reused")?.input).toEqual({ command: "date" });
    expect(byId.get("tool-main")?.partialInput).toBeUndefined();
    expect(byId.get("tool-forwarded")?.partialInput).toBeUndefined();
    expect(byId.get("tool-reused")?.partialInput).toBeUndefined();
  });

  test("a delta without a block index is ignored", () => {
    const seeded = startedPartialTool();
    const next = applyEvents(
      seeded.model,
      seeded.index,
      [
        protocol(
          streamLine(
            {
              type: "content_block_delta",
              delta: { type: "input_json_delta", partial_json: '{"command":"wrong"}' }
            },
            "missing-index"
          )
        )
      ],
      1001
    );

    expect(toolBlocks(next)[0].input).toEqual({});
    expect(toolBlocks(next)[0].partialInput).toBeUndefined();
  });

  test("stop clears raw JSON but keeps the last valid preview", () => {
    const seeded = startedPartialTool();
    let model = applyEvents(
      seeded.model,
      seeded.index,
      [
        protocol(
          streamLine(
            {
              type: "content_block_delta",
              index: 0,
              delta: { type: "input_json_delta", partial_json: '{"command":"echo ok"}' }
            },
            "valid-preview"
          )
        )
      ],
      1001
    );
    expect(toolBlocks(model)[0].input).toEqual({ command: "echo ok" });

    model = applyEvents(
      model,
      seeded.index,
      [
        protocol(
          streamLine(
            {
              type: "content_block_delta",
              index: 0,
              delta: { type: "input_json_delta", partial_json: ", not-json" }
            },
            "malformed-final"
          )
        ),
        protocol(streamLine({ type: "content_block_stop", index: 0 }, "block-stop"))
      ],
      1002
    );

    const block = toolBlocks(model)[0];
    expect(block.input).toEqual({ command: "echo ok" });
    expect(block.partialInput).toBeUndefined();
    expect(block.inputComplete).toBe(true);
  });

  test("an authoritative assistant frame clears the mutable raw prefix", () => {
    const seeded = startedPartialTool();
    let model = applyEvents(
      seeded.model,
      seeded.index,
      [
        protocol(
          streamLine(
            {
              type: "content_block_delta",
              index: 0,
              delta: { type: "input_json_delta", partial_json: '{"command":"partial' }
            },
            "partial-before-full"
          )
        )
      ],
      1001
    );
    model = applyLine(
      model,
      seeded.index,
      assistantTool("full-frame", "message-main", "tool-main", "Bash", { command: "exact" }),
      1002
    );

    const block = toolBlocks(model)[0];
    expect(block.input).toEqual({ command: "exact" });
    expect(block.partialInput).toBeUndefined();
  });

  test("aborting a turn releases raw partial input", () => {
    const seeded = startedPartialTool();
    let model = applyEvents(
      seeded.model,
      seeded.index,
      [
        protocol(
          streamLine(
            {
              type: "content_block_delta",
              index: 0,
              delta: { type: "input_json_delta", partial_json: '{"command":"sleep 10"' }
            },
            "partial-before-abort"
          )
        )
      ],
      1001
    );
    expect(toolBlocks(model)[0].partialInput).toBeDefined();

    model = applyLine(
      model,
      seeded.index,
      {
        type: "result",
        subtype: "error_during_execution",
        is_error: true,
        terminal_reason: "aborted_streaming",
        result: "Interrupted",
        uuid: "abort-result"
      } as ProtocolLine,
      1002
    );

    expect(toolBlocks(model)[0].partialInput).toBeUndefined();
  });
});

describe("explicit fold intent survives a continuation reopen", () => {
  test("a reader-folded completed turn remains folded while it streams again", () => {
    const index = createIndex();
    let model = createModel();
    model = applyLine(model, index, user("fold-user", "run it"), 1);
    model = applyLine(
      model,
      index,
      assistantTool("fold-tool-frame", "fold-tool-message", "fold-tool", "Read", {
        file_path: "/tmp/fold.txt"
      }),
      2
    );
    model = applyLine(model, index, result("fold-first-result"), 3);
    model = applyLocalAction(
      model,
      index,
      { kind: "toggleFold", turnId: model.turns[0].id, folded: true },
      4
    );

    model = applyLine(
      model,
      index,
      streamLine({ type: "message_start", message: { id: "fold-summary-leg" } }, "fold-summary-start"),
      5
    );

    expect(model.turns[0].state).toBe("streaming");
    expect(model.turns[0].foldOverride).toBe(true);
    expect(model.turns[0].folded).toBe(true);

    model = applyLine(model, index, result("fold-summary-result"), 6);
    expect(model.turns[0].folded).toBe(true);
    expect(model.turns[0].foldOverride).toBe(true);
  });
});

describe("rewind prunes state unreachable from the retained prefix", () => {
  test("discarded agents, tasks, indexes, and pending relay blocks are removed", () => {
    const index = createIndex();
    let model = createModel();

    model = applyLine(model, index, user("keep-user", "keep this"), 1);
    model = applyLine(
      model,
      index,
      assistantTool("keep-agent-frame", "keep-agent-message", "agent-kept", "Agent", {
        description: "Kept agent",
        prompt: "keep"
      }),
      2
    );
    model = applyLine(
      model,
      index,
      {
        type: "system",
        subtype: "task_started",
        task_id: "task-kept",
        tool_use_id: "agent-kept",
        task_type: "local_agent",
        description: "Kept agent",
        status: "completed",
        uuid: "task-kept-frame"
      } as ProtocolLine,
      3
    );
    model = applyLine(model, index, result("keep-result"), 4);

    model = applyLocalAction(
      model,
      index,
      {
        kind: "localSend",
        uuid: "drop-relay",
        text: "discarded relay",
        atMs: 5,
        relay: { toolUseId: "agent-kept", description: "Kept agent" }
      },
      5
    );
    model = applyLine(
      model,
      index,
      assistantTool("drop-agent-frame", "drop-agent-message", "agent-dropped", "Agent", {
        description: "Dropped agent",
        prompt: "drop"
      }),
      6
    );
    model = applyLine(
      model,
      index,
      {
        type: "system",
        subtype: "task_started",
        task_id: "task-dropped",
        tool_use_id: "agent-dropped",
        task_type: "local_agent",
        description: "Dropped agent",
        status: "running",
        uuid: "task-dropped-frame"
      } as ProtocolLine,
      7
    );
    model = applyLine(model, index, result("drop-result"), 8);

    expect(model.agentThreads["agent-kept"].blocks.some((block) => block.kind === "userText" && block.pending)).toBe(true);
    expect(index.seenUuids.has("drop-agent-frame")).toBe(true);

    model = applyLocalAction(
      model,
      index,
      { kind: "truncateBeforeUserMessage", uuid: "drop-relay" },
      9
    );

    expect(Object.keys(model.agentThreads)).toEqual(["agent-kept"]);
    expect(Object.keys(model.tasksById)).toEqual(["task-kept"]);
    expect(model.agentRootIds).toEqual(["agent-kept"]);
    expect(model.relays).toEqual({});
    expect(
      model.agentThreads["agent-kept"].blocks.some(
        (block) => block.kind === "userText" && block.uuid === "drop-relay" && block.pending
      )
    ).toBe(false);
    expect(index.toolLocations.has("agent-dropped")).toBe(false);
    expect(index.taskToTool.has("task-dropped")).toBe(false);
    expect(index.seenUuids.has("drop-agent-frame")).toBe(false);
    expect(index.seenUuids.has("keep-agent-frame")).toBe(true);
  });
});

describe("HarnessStore fallback scheduling", () => {
  test("flushNow cancels a timeout fallback with clearTimeout", () => {
    const originalRaf = globalThis.requestAnimationFrame;
    const originalCancelRaf = globalThis.cancelAnimationFrame;
    const originalSetTimeout = globalThis.setTimeout;
    const originalClearTimeout = globalThis.clearTimeout;
    let timeoutClears = 0;
    let frameCancels = 0;

    Object.defineProperty(globalThis, "requestAnimationFrame", {
      configurable: true,
      value: undefined
    });
    globalThis.cancelAnimationFrame = (() => {
      frameCancels += 1;
    }) as typeof cancelAnimationFrame;
    globalThis.setTimeout = (() => 4242) as unknown as typeof setTimeout;
    globalThis.clearTimeout = ((handle: ReturnType<typeof setTimeout>) => {
      if (Number(handle) === 4242) timeoutClears += 1;
    }) as typeof clearTimeout;

    try {
      const store = new HarnessStore();
      store.receive([{ kind: "runStarted", runId: "fallback-run" }]);
      expect(() => store.flushNow()).not.toThrow();
      expect(timeoutClears).toBe(1);
      expect(frameCancels).toBe(0);
      expect(store.getSnapshot().runId).toBe("fallback-run");
    } finally {
      Object.defineProperty(globalThis, "requestAnimationFrame", {
        configurable: true,
        value: originalRaf
      });
      globalThis.cancelAnimationFrame = originalCancelRaf;
      globalThis.setTimeout = originalSetTimeout;
      globalThis.clearTimeout = originalClearTimeout;
    }
  });
});

describe("highlight cache budgeting", () => {
  test("large unique entries cannot exceed the reported byte budget", () => {
    clearHighlightCache();
    for (let entry = 0; entry < 220; entry += 1) {
      const code = Array.from(
        { length: 700 },
        (_, line) => `const value_${entry}_${line} = ${entry + line};`
      ).join("\n");
      highlightToHtml(code, "javascript");
    }
    const stats = highlightCacheStats();
    expect(stats.entries).toBeGreaterThan(0);
    expect(stats.bytes).toBeLessThanOrEqual(stats.budgetBytes);
    clearHighlightCache();
  });
});

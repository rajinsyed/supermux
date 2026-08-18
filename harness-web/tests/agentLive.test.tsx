import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, render } from "@testing-library/react";
import { useRef, useSyncExternalStore } from "react";
import { taskBridgeStub } from "./bridgeStub";
import {
  FWD_INNER_TOOL_USE_ID,
  FWD_LIVE_TOOL_USE_ID,
  fwdLiveFixture,
  fwdNestedFixture,
  RELAY_AGENT_TOOL_USE_ID,
  relayFixture
} from "../src/dev/fixtures/round4";
import { threadBlocks } from "../src/model/agentThreads";
import { HarnessStore } from "../src/model/store";
import { applyLine, applyLocalAction, createIndex, createModel } from "../src/model/transcript";
import type { TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { AgentChatView } from "../src/ui/views/AgentChatView";

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

/**
 * The agent view, wired to the real store the way `App` wires it: one
 * `useSyncExternalStore` subscription, thread read out of the snapshot.
 *
 * Rendering off a pre-built model would prove nothing about the reported bug —
 * "subagents transcript only updates when the subagent is done" is a claim
 * about what reaches the SCREEN as frames arrive, so the frames have to go
 * through the store one at a time and the assertion has to be on the DOM.
 */
function LiveView({ store, toolUseId }: { store: HarnessStore; toolUseId: string }) {
  const model = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const scrollRef = useRef<HTMLDivElement>(null);
  return (
    <AgentChatView
      thread={model.agentThreads[toolUseId]}
      threads={model.agentThreads}
      relays={[]}
      scrollRef={scrollRef}
      onHydrate={() => undefined}
    />
  );
}

function mount(node: React.ReactElement) {
  window.supermuxHarnessMock = taskBridgeStub as never;
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

/** How many blocks the agent's chat is currently rendering. */
function renderedBlocks(container: HTMLElement): number {
  return container.querySelectorAll(
    ".agent-view .thread-user, .agent-view .assistant-text, .agent-view .thinking, .agent-view .tool-card"
  ).length;
}

describe("an open agent view renders each block as its frame arrives", () => {
  /**
   * The probe this replays (fwd.jsonl) has the agent's frames spread over five
   * seconds: prompt at t+5.2s, thinking at t+7.3s, text at t+8.9s, its Bash
   * tool_use at t+9.7s, the tool_result at t+9.8s and its closing text at
   * t+10.9s — with the Task itself only completing at t+10.9s. So a view that
   * fills in once at the end is losing five seconds of work the wire already
   * delivered, which is exactly what was reported.
   */
  test("the thread GROWS through the run rather than appearing at completion", async () => {
    const store = new HarnessStore();
    const { container } = mount(<LiveView store={store} toolUseId={FWD_LIVE_TOOL_USE_ID} />);

    const counts: number[] = [];
    for (const line of fwdLiveFixture) {
      await act(async () => {
        store.receive([{ kind: "protocol", line }]);
        store.flushNow();
      });
      counts.push(renderedBlocks(container));
    }

    const distinct = Array.from(new Set(counts.filter((count) => count > 0)));
    // Not merely "it ended up populated": it has to have been populated in
    // STEPS. One distinct non-zero count means every block landed together,
    // which is the bug.
    expect(distinct.length).toBeGreaterThan(2);
    // And it never went backwards — a thread that resets mid-run is the
    // disk-replay race, not live growth.
    for (let i = 1; i < counts.length; i += 1) {
      expect(counts[i]).toBeGreaterThanOrEqual(counts[i - 1]);
    }

    // The agent's own work is on screen BEFORE its Task settles.
    const settledAt = fwdLiveFixture.findIndex((line) => (line as { type?: string }).type === "result");
    expect(settledAt).toBeGreaterThan(0);
    expect(counts[settledAt - 1]).toBeGreaterThan(1);
  });

  test("a nested agent's view is live too, not only the top-level one", async () => {
    const store = new HarnessStore();
    const { container } = mount(<LiveView store={store} toolUseId={FWD_INNER_TOOL_USE_ID} />);
    const counts: number[] = [];
    for (const line of fwdNestedFixture) {
      await act(async () => {
        store.receive([{ kind: "protocol", line }]);
        store.flushNow();
      });
      counts.push(renderedBlocks(container));
    }
    expect(Array.from(new Set(counts.filter((c) => c > 0))).length).toBeGreaterThan(2);
  });
});

describe("a disk replay never fights the live frames", () => {
  /**
   * The race that made an agent's chat double itself.
   *
   * Opening a live agent's view fires the disk fallback while its frames are
   * still arriving; the file is a stale prefix of the same conversation, so
   * keeping both drew every message twice. The reducer already refused a
   * hydration ONTO live blocks — this is the other direction, where the replay
   * got there first.
   */
  test("live frames replace a replay that arrived first", () => {
    const index = createIndex();
    let model = createModel();
    let consumed = 0;
    for (const line of fwdNestedFixture) {
      model = applyLine(model, index, line, Date.now());
      consumed += 1;
      if (model.agentThreads[FWD_INNER_TOOL_USE_ID]) break;
    }
    const before = model.agentThreads[FWD_INNER_TOOL_USE_ID];
    expect(before.blocks.length).toBe(0);

    model = applyLocalAction(
      model,
      index,
      {
        kind: "hydrateThread",
        toolUseId: FWD_INNER_TOOL_USE_ID,
        events: [
          {
            type: "assistant",
            message: { id: "dm", role: "assistant", content: [{ type: "text", text: "stale disk copy" }] },
            uuid: "disk-a"
          } as ProtocolLine
        ]
      },
      Date.now()
    );
    expect(model.agentThreads[FWD_INNER_TOOL_USE_ID].hydratedFromDisk).toBe(true);

    for (const line of fwdNestedFixture.slice(consumed)) {
      model = applyLine(model, index, line, Date.now());
    }
    const after = model.agentThreads[FWD_INNER_TOOL_USE_ID];
    expect(after.hydratedFromDisk).toBeUndefined();
    expect(after.hasLiveFrames).toBe(true);
    const texts = after.blocks.filter((b) => b.kind === "text").map((b) => b.text);
    expect(texts.some((text) => text.includes("stale disk copy"))).toBe(false);
    expect(after.blocks.some((b) => b.kind === "tool" && b.name === "Bash")).toBe(true);
  });
});

describe("every agent shows the brief it was given", () => {
  /**
   * The prompt reaches the pane by three routes and no one of them covers every
   * agent, which is why it showed "on some subagents … but on others i cant".
   * `task_started.prompt` is the route that is always there for a local agent,
   * and it is what the resolver falls back to.
   */
  test("a thread whose forwarded prompt frame never arrived still has one", () => {
    // The relay probe's agent: it is spawned and its Bash frames are forwarded,
    // but the CLI sends no opening `user` text frame for it at all.
    const index = createIndex();
    let model: TranscriptModel = createModel();
    for (const line of relayFixture) model = applyLine(model, index, line, Date.now());
    const thread = model.agentThreads[RELAY_AGENT_TOOL_USE_ID];
    expect(thread.blocks.some((b) => b.kind === "userText" && b.prompt)).toBe(false);
    expect(thread.prompt).toContain("sleep 5");

    const blocks = threadBlocks(thread);
    const first = blocks[0];
    expect(first.kind).toBe("userText");
    expect(first.kind === "userText" && first.prompt).toBe(true);
    expect(first.kind === "userText" && first.text).toContain("sleep 5");
  });

  test("a thread that DOES have its prompt frame is left alone", () => {
    // No second copy, and the real frame keeps its uuid: it is the authority
    // whenever it exists.
    const index = createIndex();
    let model: TranscriptModel = createModel();
    for (const line of fwdNestedFixture) model = applyLine(model, index, line, Date.now());
    const thread = model.agentThreads[FWD_INNER_TOOL_USE_ID];
    const blocks = threadBlocks(thread);
    expect(blocks).toBe(thread.blocks);
    expect(blocks.filter((b) => b.kind === "userText" && b.prompt).length).toBe(1);
  });

  test("the brief is on screen before the agent has said anything", () => {
    const store = new HarnessStore();
    const { container } = mount(<LiveView store={store} toolUseId={RELAY_AGENT_TOOL_USE_ID} />);
    // Up to and including the agent's task_started: it exists, it has its
    // prompt, and it has produced no output yet.
    const upToStart: ProtocolLine[] = [];
    for (const line of relayFixture) {
      upToStart.push(line);
      const frame = line as { type?: string; subtype?: string };
      if (frame.type === "system" && frame.subtype === "task_started") break;
    }
    act(() => {
      store.receive(upToStart.map((line) => ({ kind: "protocol" as const, line })));
      store.flushNow();
    });
    const prompt = container.querySelector(".thread-user.is-prompt");
    expect(prompt).not.toBeNull();
    expect(prompt!.textContent).toContain("sleep 5");
  });

  test("a nested agent gets its prompt from its own task_started", () => {
    // Its `task_started` arrives BEFORE the assistant frame carrying its Agent
    // tool_use, so a rule that only enriched threads that already existed threw
    // that frame — and the prompt on it — away.
    const index = createIndex();
    let model: TranscriptModel = createModel();
    for (const line of fwdNestedFixture) {
      model = applyLine(model, index, line, Date.now());
      const frame = line as { type?: string; subtype?: string; tool_use_id?: string };
      if (
        frame.type === "system" &&
        frame.subtype === "task_started" &&
        frame.tool_use_id === FWD_INNER_TOOL_USE_ID
      ) {
        break;
      }
    }
    const thread = model.agentThreads[FWD_INNER_TOOL_USE_ID];
    expect(thread).toBeDefined();
    expect(thread.prompt).toContain("echo inner-ok");
  });
});

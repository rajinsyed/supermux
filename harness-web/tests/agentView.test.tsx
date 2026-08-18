import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { useRef, useState } from "react";
import type { HarnessBridge } from "../src/bridge";
import { taskBridgeStub } from "./bridgeStub";
import {
  FWD_INNER_TOOL_USE_ID,
  FWD_OUTER_TOOL_USE_ID,
  fwdNestedFixture
} from "../src/dev/fixtures/round4";
import { applyLocalAction, createIndex, replayLines } from "../src/model/transcript";
import type { TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";
import { CopyProvider, useCopy } from "../src/ui/CopyContext";
import { Composer } from "../src/ui/composer/Composer";
import { AgentChatView } from "../src/ui/views/AgentChatView";
import { OpenViewContext } from "../src/ui/views/OpenViewContext";
import { useViewRouter } from "../src/ui/views/useViewRouter";
import { ViewBreadcrumb } from "../src/ui/views/ViewBreadcrumb";
import type { HarnessView } from "../src/ui/views/viewStack";

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

function installBridge(overrides: Partial<HarnessBridge>): { calls: string[] } {
  const calls: string[] = [];
  window.supermuxHarnessMock = { ...taskBridgeStub, ...overrides } as never;
  return { calls };
}

function View({ model, toolUseId }: { model: TranscriptModel; toolUseId: string }) {
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

async function flush(ms = 20) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

describe("the agent chat view", () => {
  const model = replayLines(fwdNestedFixture);

  test("it renders the thread with the MAIN chat's own renderers", () => {
    // Not a second, thinner set of renderers: a tool call inside an agent has to
    // look and behave like a tool call in the main chat, or the reader is
    // learning two interfaces for one thing.
    const { container } = mount(<View model={model} toolUseId={FWD_INNER_TOOL_USE_ID} />);
    expect(container.querySelector(".tool-card")).not.toBeNull();
    expect(container.querySelector(".assistant-text")).not.toBeNull();
  });

  test("the agent's brief reads as a prompt, not as someone speaking", () => {
    const { container } = mount(<View model={model} toolUseId={FWD_INNER_TOOL_USE_ID} />);
    const prompt = container.querySelector(".thread-user.is-prompt")!;
    expect(prompt).not.toBeNull();
    expect(prompt.textContent).toContain("Prompt");
    expect(prompt.textContent).toContain("echo inner-ok");
  });

  test("the header names the agent and reports what it cost", () => {
    const { container } = mount(<View model={model} toolUseId={FWD_OUTER_TOOL_USE_ID} />);
    expect(container.querySelector(".agent-view-name")!.textContent).toBe("Outer relay");
    expect(container.querySelector(".agent-view-meta")!.textContent).toContain("general-purpose");
  });

  test("a child agent is a row that navigates, not blocks rendered inline", () => {
    // Descending is a NAVIGATION, so the stack records it and Escape returns
    // here rather than to the main chat.
    const opened: HarnessView[] = [];
    const { container } = mount(
      <OpenViewContext.Provider value={(view) => opened.push(view)}>
        <View model={model} toolUseId={FWD_OUTER_TOOL_USE_ID} />
      </OpenViewContext.Provider>
    );
    const child = container.querySelector(".agent-view-child")!;
    expect(child).not.toBeNull();
    // The row wears the child's NAME; its wire id is routing data, not copy.
    expect(child.textContent).toContain("Inner counter");
    expect(child.textContent).not.toContain(FWD_INNER_TOOL_USE_ID);
    fireEvent.click(child);
    expect(opened).toEqual([{ kind: "agent", toolUseId: FWD_INNER_TOOL_USE_ID }]);
  });

  test("a thread with no live frames loads from disk and replays into it", async () => {
    installBridge({
      async loadSubagentTranscript() {
        return {
          events: [
            {
              type: "assistant",
              message: {
                id: "m1",
                role: "assistant",
                content: [{ type: "text", text: "read off disk" }]
              },
              uuid: "disk-1"
            } as ProtocolLine
          ],
          truncated: false
        };
      }
    });
    const hydrated: { toolUseId: string; events: ProtocolLine[] }[] = [];
    // A thread the dock knows about with nothing in it — a resumed session, or
    // forwarding that started after the agent did.
    const empty: TranscriptModel = {
      ...model,
      agentThreads: {
        [FWD_OUTER_TOOL_USE_ID]: {
          ...model.agentThreads[FWD_OUTER_TOOL_USE_ID],
          blocks: [],
          hasLiveFrames: undefined
        }
      }
    };
    function Harness() {
      const scrollRef = useRef<HTMLDivElement>(null);
      return (
        <AgentChatView
          thread={empty.agentThreads[FWD_OUTER_TOOL_USE_ID]}
          relays={[]}
          scrollRef={scrollRef}
          onHydrate={(toolUseId, events) => hydrated.push({ toolUseId, events })}
        />
      );
    }
    mount(<Harness />);
    await flush(40);
    expect(hydrated.length).toBe(1);
    expect(hydrated[0].toolUseId).toBe(FWD_OUTER_TOOL_USE_ID);
  });

  test("the reducer refuses to hydrate a thread that already has live frames", () => {
    // Live frames always win: folding a disk replay into a thread that has them
    // would draw every message twice.
    const index = createIndex();
    const before = model.agentThreads[FWD_OUTER_TOOL_USE_ID].blocks.length;
    const next = applyLocalAction(
      model,
      index,
      {
        kind: "hydrateThread",
        toolUseId: FWD_OUTER_TOOL_USE_ID,
        events: [
          {
            type: "assistant",
            message: { id: "m9", role: "assistant", content: [{ type: "text", text: "dupe" }] },
            uuid: "dupe-1"
          } as ProtocolLine
        ]
      },
      Date.now()
    );
    expect(next.agentThreads[FWD_OUTER_TOOL_USE_ID].blocks.length).toBe(before);
    expect(next).toBe(model);
  });

  test("a missing transcript says so calmly rather than erroring", async () => {
    installBridge({
      async loadSubagentTranscript() {
        return { events: [], truncated: false, missing: true };
      }
    });
    const empty: TranscriptModel = {
      ...model,
      agentThreads: {
        [FWD_OUTER_TOOL_USE_ID]: {
          ...model.agentThreads[FWD_OUTER_TOOL_USE_ID],
          blocks: [],
          hasLiveFrames: undefined
        }
      }
    };
    const { container } = mount(<View model={empty} toolUseId={FWD_OUTER_TOOL_USE_ID} />);
    await flush(40);
    expect(container.querySelector(".drill-status")!.textContent).toContain(
      "No transcript for this agent yet"
    );
  });

  test("a failed load offers a retry rather than a dead end", async () => {
    let attempts = 0;
    installBridge({
      loadSubagentTranscript: () => {
        attempts += 1;
        return Promise.reject(new Error("nope"));
      }
    });
    const empty: TranscriptModel = {
      ...model,
      agentThreads: {
        [FWD_OUTER_TOOL_USE_ID]: {
          ...model.agentThreads[FWD_OUTER_TOOL_USE_ID],
          blocks: [],
          hasLiveFrames: undefined
        }
      }
    };
    const { container, getByText } = mount(<View model={empty} toolUseId={FWD_OUTER_TOOL_USE_ID} />);
    await flush(40);
    expect(container.querySelector(".drill-status.is-error")).not.toBeNull();
    expect(attempts).toBe(1);
    fireEvent.click(getByText("Try again"));
    await flush(40);
    expect(attempts).toBe(2);
  });

  test("a view for an agent the pane has never heard of is honest about it", () => {
    const { container } = mount(<View model={model} toolUseId="toolu_nope" />);
    expect(container.querySelector(".drill-status")).not.toBeNull();
  });
});

/**
 * Escape, through the real router, from a real focused element.
 *
 * The reflex has to work wherever focus is, which is why it is bound at the
 * window — and it has to DEFER to anything that owns Escape more locally, which
 * is why it checks `defaultPrevented`.
 */
describe("escape navigation", () => {
  function Router({ model }: { model: TranscriptModel }) {
    const copy = useCopy();
    const router = useViewRouter(model, copy);
    return (
      <div>
        <ViewBreadcrumb
          stack={router.stack}
          labelFor={router.labelFor}
          onBack={router.back}
          onOpen={router.open}
        />
        <div data-testid="view">{router.view.kind}</div>
        <button type="button" onClick={() => router.open({ kind: "agent", toolUseId: FWD_OUTER_TOOL_USE_ID })}>
          open outer
        </button>
        <button type="button" onClick={() => router.open({ kind: "agent", toolUseId: FWD_INNER_TOOL_USE_ID })}>
          open inner
        </button>
      </div>
    );
  }

  function pressEscape(): KeyboardEvent {
    const event = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    act(() => {
      window.dispatchEvent(event);
    });
    return event;
  }

  test("escape walks back one level per press and stops at main", () => {
    const model = replayLines(fwdNestedFixture);
    const { getByText, getByTestId } = mount(<Router model={model} />);
    fireEvent.click(getByText("open outer"));
    fireEvent.click(getByText("open inner"));
    expect(getByTestId("view").textContent).toBe("agent");
    expect(pressEscape().defaultPrevented).toBe(true);
    expect(pressEscape().defaultPrevented).toBe(true);
    expect(getByTestId("view").textContent).toBe("main");
  });

  test("on the main view escape is left alone for the composer's interrupt", () => {
    // Swallowing it here would make Stop stop working the moment the router
    // mounted.
    const model = replayLines(fwdNestedFixture);
    mount(<Router model={model} />);
    expect(pressEscape().defaultPrevented).toBe(false);
  });

  test("escape defers to a handler that already claimed it", () => {
    const model = replayLines(fwdNestedFixture);
    const { getByText, getByTestId } = mount(<Router model={model} />);
    fireEvent.click(getByText("open outer"));
    const event = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    event.preventDefault();
    act(() => {
      window.dispatchEvent(event);
    });
    // A modal or an open popover that consumed Escape must not ALSO lose the
    // reader their place in the view stack.
    expect(getByTestId("view").textContent).toBe("agent");
  });

  test("the breadcrumb shows the trail and its back button pops", () => {
    const model = replayLines(fwdNestedFixture);
    const { getByText, getByTestId, container } = mount(<Router model={model} />);
    fireEvent.click(getByText("open outer"));
    const trail = container.querySelector(".view-crumb-trail")!;
    expect(trail.textContent).toContain("Claude");
    expect(trail.textContent).toContain("Outer relay");
    expect(container.querySelector(".view-crumb-current")!.textContent).toBe("Outer relay");
    fireEvent.click(getByText("Back"));
    expect(getByTestId("view").textContent).toBe("main");
  });

  test("the main view has no breadcrumb at all", () => {
    // A crumb reading just "Claude" is a row of chrome that says nothing.
    const model = replayLines(fwdNestedFixture);
    const { container } = mount(<Router model={model} />);
    expect(container.querySelector(".view-crumbs")).toBeNull();
  });

  test("the composer does not swallow escape in an agent view", () => {
    // Found in the browser, not by a unit test: the composer claimed Escape
    // unconditionally, which was invisible while the composer was the only
    // thing Escape meant. With a view stack it meant the reader could not
    // leave an agent view by keyboard at all — the caret is in the composer,
    // which is where typing puts it.
    const { container } = render(
      <CopyProvider dict={undefined}>
        <Composer
          disabled={false}
          running
          agentName="Slow summarizer"
          awaitingPermission={false}
          planPending={false}
          onPlanImplement={() => undefined}
          onPlanRefine={() => undefined}
          onPlanKeepPlanning={() => undefined}
          queued={[]}
          commands={[]}
          permissionMode="default"
          draft=""
          onDraftChange={() => undefined}
          onSend={() => undefined}
          onInterrupt={() => undefined}
          onCancelQueued={() => undefined}
          onCyclePermissionMode={() => undefined}
          fetchFileSuggestions={async () => []}
          onPickFiles={async () => []}
        />
      </CopyProvider>
    );
    const input = container.querySelector(".composer-input")!;
    const event = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    act(() => {
      input.dispatchEvent(event);
    });
    expect(event.defaultPrevented).toBe(false);
    // And no Stop button, because interrupting MAIN is not what a reader
    // inside an agent's conversation is asking for.
    expect(container.querySelector(".btn-stop")).toBeNull();
  });

  test("on MAIN the composer still owns escape while a turn runs", () => {
    const interrupts: boolean[] = [];
    const { container } = render(
      <CopyProvider dict={undefined}>
        <Composer
          disabled={false}
          running
          awaitingPermission={false}
          planPending={false}
          onPlanImplement={() => undefined}
          onPlanRefine={() => undefined}
          onPlanKeepPlanning={() => undefined}
          queued={[]}
          commands={[]}
          permissionMode="default"
          draft=""
          onDraftChange={() => undefined}
          onSend={() => undefined}
          onInterrupt={(cancel) => interrupts.push(cancel)}
          onCancelQueued={() => undefined}
          onCyclePermissionMode={() => undefined}
          fetchFileSuggestions={async () => []}
          onPickFiles={async () => []}
        />
      </CopyProvider>
    );
    const input = container.querySelector(".composer-input")!;
    const event = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    act(() => {
      input.dispatchEvent(event);
    });
    expect(event.defaultPrevented).toBe(true);
    expect(interrupts.length).toBe(1);
  });

  test("a view whose subject disappears is pruned off the stack", () => {
    // `reset` and a rewind both drop threads the stack may point at, and an
    // agent view with no agent is an empty screen you cannot escape from in
    // one press.
    function Pruning() {
      const copy = useCopy();
      const [model, setModel] = useState(() => replayLines(fwdNestedFixture));
      const router = useViewRouter(model, copy);
      return (
        <div>
          <div data-testid="view">{router.view.kind}</div>
          <button type="button" onClick={() => router.open({ kind: "agent", toolUseId: FWD_OUTER_TOOL_USE_ID })}>
            open
          </button>
          <button
            type="button"
            onClick={() => setModel((current) => ({ ...current, agentThreads: {}, agentRootIds: [] }))}
          >
            drop
          </button>
        </div>
      );
    }
    const { getByText, getByTestId } = mount(<Pruning />);
    fireEvent.click(getByText("open"));
    expect(getByTestId("view").textContent).toBe("agent");
    fireEvent.click(getByText("drop"));
    expect(getByTestId("view").textContent).toBe("main");
  });
});

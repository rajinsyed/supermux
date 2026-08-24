import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, render, waitFor } from "@testing-library/react";
import { useRef } from "react";
import type { HarnessBridge } from "../src/bridge";
import { FWD_OUTER_TOOL_USE_ID, fwdNestedFixture } from "../src/dev/fixtures/round4";
import { replayLines } from "../src/model/transcript";
import type { TranscriptModel } from "../src/model/types";
import type { ProtocolLine, SubagentTranscript } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { SubagentTranscriptResourceProvider } from "../src/ui/subagentTranscriptResource";
import { useSubagentTranscript } from "../src/ui/tools/SubagentTranscript";
import { AgentChatView } from "../src/ui/views/AgentChatView";
import { useAgentDocument } from "../src/ui/workflow/useAgentDocument";

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

const WORKFLOW_TARGET = { workflowRunId: "wf-run", agentId: "agent-1" };

type RevisionedTranscript = SubagentTranscript & {
  revision: number;
  replace: boolean;
  droppedEventCount: number;
};

function user(uuid: string, text: string): ProtocolLine {
  return {
    type: "user",
    uuid,
    message: { role: "user", content: text }
  };
}

function assistant(uuid: string, text: string): ProtocolLine {
  return {
    type: "assistant",
    uuid,
    message: {
      id: `message-${uuid}`,
      role: "assistant",
      content: [{ type: "text", text }]
    }
  };
}

function response(
  revision: number,
  values: Partial<RevisionedTranscript> = {}
): RevisionedTranscript {
  return {
    revision,
    replace: false,
    droppedEventCount: 0,
    events: [],
    truncated: false,
    ...values
  };
}

async function unusedBridgeMethod(): Promise<never> {
  throw new Error("unused bridge method");
}

function installBridge(load: HarnessBridge["loadSubagentTranscript"]): void {
  const bridge: HarnessBridge = {
    context: unusedBridgeMethod,
    listSessions: unusedBridgeMethod,
    loadSessionHistory: unusedBridgeMethod,
    start: unusedBridgeMethod,
    restart: unusedBridgeMethod,
    openSessionInNewPane: unusedBridgeMethod,
    send: unusedBridgeMethod,
    interrupt: unusedBridgeMethod,
    cancelQueued: unusedBridgeMethod,
    stop: unusedBridgeMethod,
    setModel: unusedBridgeMethod,
    setPermissionMode: unusedBridgeMethod,
    respondPermission: unusedBridgeMethod,
    renameSession: unusedBridgeMethod,
    getContextUsage: unusedBridgeMethod,
    fileSuggestions: unusedBridgeMethod,
    pickFiles: unusedBridgeMethod,
    readImage: unusedBridgeMethod,
    openFile: unusedBridgeMethod,
    copyText: unusedBridgeMethod,
    saveFile: unusedBridgeMethod,
    notify: unusedBridgeMethod,
    saveDraft: unusedBridgeMethod,
    getBinarySetting: unusedBridgeMethod,
    setBinaryPath: unusedBridgeMethod,
    rewindPreview: unusedBridgeMethod,
    rewind: unusedBridgeMethod,
    stopTask: unusedBridgeMethod,
    backgroundTask: unusedBridgeMethod,
    loadSubagentTranscript: load,
    readTaskOutput: unusedBridgeMethod
  };
  window.supermuxHarnessMock = bridge;
}

function deferred<T>() {
  let resolve: (value: T) => void = () => undefined;
  let reject: (reason?: unknown) => void = () => undefined;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

async function flushMicrotasks(): Promise<void> {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

type TranscriptResource = ReturnType<typeof useSubagentTranscript>;

function TranscriptProbe({
  target = WORKFLOW_TARGET,
  open = true,
  tick,
  capture
}: {
  target?: { taskId?: string; workflowRunId?: string; agentId?: string };
  open?: boolean;
  tick?: number;
  capture?(value: TranscriptResource): void;
}) {
  const resource = useSubagentTranscript(target, open, tick);
  capture?.(resource);
  return (
    <pre
      data-testid="resource"
      data-phase={resource.phase}
      data-meta={resource.meta?.description ?? ""}
      data-truncated={String(resource.truncated)}
    >
      {JSON.stringify(resource.model)}
    </pre>
  );
}

function Root({ children }: { children: React.ReactNode }) {
  return (
    <CopyProvider dict={undefined}>
      <SubagentTranscriptResourceProvider generation={0}>
        {children}
      </SubagentTranscriptResourceProvider>
    </CopyProvider>
  );
}

describe("shared incremental subagent transcript resources", () => {
  test("reconciles append deltas, prefix drops, unchanged metadata, and metadata deletion", async () => {
    const replies = [
      response(1, {
        replace: true,
        events: [user("user-1", "full prompt"), assistant("assistant-1", "first outcome")],
        meta: { agentType: "worker", description: "First agent", spawnDepth: 1 }
      }),
      response(2, { events: [assistant("assistant-2", "new outcome")] }),
      response(3, {
        droppedEventCount: 1,
        events: [assistant("assistant-3", "latest outcome")],
        truncated: true
      }),
      response(4, { meta: null }),
      response(4)
    ];
    const calls: Array<{ afterRevision?: number }> = [];
    installBridge(async (params) => {
      calls.push(params);
      return replies[calls.length - 1];
    });
    let current: TranscriptResource | undefined;
    const view = render(
      <Root>
        <TranscriptProbe tick={1} capture={(value) => (current = value)} />
      </Root>
    );
    await waitFor(() => expect(current?.phase).toBe("ready"));
    expect(calls[0].afterRevision).toBeUndefined();
    expect(view.getByTestId("resource").textContent).toContain("full prompt");
    expect(current?.meta?.description).toBe("First agent");

    view.rerender(
      <Root>
        <TranscriptProbe tick={2} capture={(value) => (current = value)} />
      </Root>
    );
    await waitFor(() => expect(calls).toHaveLength(2));
    expect(calls[1].afterRevision).toBe(1);
    await waitFor(() => expect(view.getByTestId("resource").textContent).toContain("new outcome"));
    expect(view.getByTestId("resource").textContent).toContain("first outcome");
    expect(current?.meta?.description).toBe("First agent");

    view.rerender(
      <Root>
        <TranscriptProbe tick={3} capture={(value) => (current = value)} />
      </Root>
    );
    await waitFor(() => expect(calls).toHaveLength(3));
    await waitFor(() => expect(view.getByTestId("resource").textContent).toContain("latest outcome"));
    expect(view.getByTestId("resource").textContent).not.toContain("full prompt");
    expect(view.getByTestId("resource").textContent).toContain("first outcome");
    expect(current?.meta?.description).toBe("First agent");
    expect(current?.truncated).toBe(true);

    view.rerender(
      <Root>
        <TranscriptProbe tick={4} capture={(value) => (current = value)} />
      </Root>
    );
    await waitFor(() => expect(calls).toHaveLength(4));
    await waitFor(() => expect(current?.meta).toBeUndefined());
    const modelBeforeUnchanged = current?.model;

    view.rerender(
      <Root>
        <TranscriptProbe tick={5} capture={(value) => (current = value)} />
      </Root>
    );
    await waitFor(() => expect(calls).toHaveLength(5));
    expect(current?.model).toBe(modelBeforeUnchanged);
  });

  test("inline transcript and workflow document share one request and reducer", async () => {
    let calls = 0;
    installBridge(async () => {
      calls += 1;
      return response(1, {
        replace: true,
        events: [user("user-1", "shared prompt"), assistant("assistant-1", "shared outcome")]
      });
    });

    function SharedSurfaces() {
      const transcript = useSubagentTranscript(WORKFLOW_TARGET, true, 1);
      const document = useAgentDocument(WORKFLOW_TARGET, true, 1);
      return (
        <div data-testid="shared" data-transcript={transcript.phase} data-document={document.phase}>
          {document.prompt}|{document.outcome}|{JSON.stringify(transcript.model)}
        </div>
      );
    }

    const view = render(
      <Root>
        <SharedSurfaces />
      </Root>
    );
    await waitFor(() => expect(view.getByTestId("shared").textContent).toContain("shared outcome"));
    expect(calls).toBe(1);
    expect(view.getByTestId("shared").textContent).toContain("shared prompt");
  });

  test("agent chat disk fallback shares the local-agent resource", async () => {
    const model = replayLines(fwdNestedFixture);
    const sourceThread = model.agentThreads[FWD_OUTER_TOOL_USE_ID];
    const target = sourceThread.taskId ?? sourceThread.agentId;
    expect(target).toBeDefined();
    const emptyThread = {
      ...sourceThread,
      blocks: [],
      hasLiveFrames: undefined,
      hydratedFromDisk: undefined
    };
    let calls = 0;
    installBridge(async () => {
      calls += 1;
      return response(1, {
        replace: true,
        events: [user("user-1", "disk prompt"), assistant("assistant-1", "disk outcome")]
      });
    });

    function SharedLocalSurfaces() {
      const scrollRef = useRef<HTMLDivElement>(null);
      const transcript = useSubagentTranscript({ taskId: target }, true, undefined);
      return (
        <>
          <div data-testid="local-resource">{JSON.stringify(transcript.model)}</div>
          <AgentChatView
            thread={emptyThread}
            relays={[]}
            scrollRef={scrollRef}
            onHydrate={() => undefined}
          />
        </>
      );
    }

    const view = render(
      <Root>
        <SharedLocalSurfaces />
      </Root>
    );
    await waitFor(() => expect(view.getByTestId("local-resource").textContent).toContain("disk outcome"));
    expect(calls).toBe(1);
  });

  test("concurrent consumers and a cached remount do not duplicate reads", async () => {
    const pending = deferred<SubagentTranscript>();
    let calls = 0;
    installBridge(() => {
      calls += 1;
      return pending.promise;
    });
    const captured: TranscriptResource[] = [];
    function Pair({ shown }: { shown: boolean }) {
      return shown ? (
        <>
          <TranscriptProbe tick={1} capture={(value) => (captured[0] = value)} />
          <TranscriptProbe tick={1} capture={(value) => (captured[1] = value)} />
        </>
      ) : null;
    }
    const view = render(
      <Root>
        <Pair shown />
      </Root>
    );
    await flushMicrotasks();
    expect(calls).toBe(1);

    pending.resolve(response(1, { replace: true, events: [assistant("assistant-1", "shared")] }));
    await waitFor(() => expect(captured[0]?.phase).toBe("ready"));
    expect(captured[0].model).toBe(captured[1].model);

    view.rerender(
      <Root>
        <Pair shown={false} />
      </Root>
    );
    view.rerender(
      <Root>
        <Pair shown />
      </Root>
    );
    await flushMicrotasks();
    expect(calls).toBe(1);
    expect(captured[0].phase).toBe("ready");
  });

  test("release then acquire transfers an in-flight reply", async () => {
    const pending = deferred<SubagentTranscript>();
    let calls = 0;
    installBridge(() => {
      calls += 1;
      return pending.promise;
    });
    let current: TranscriptResource | undefined;
    function Mount({ shown }: { shown: boolean }) {
      return shown ? <TranscriptProbe tick={7} capture={(value) => (current = value)} /> : null;
    }
    const view = render(
      <Root>
        <Mount shown />
      </Root>
    );
    await flushMicrotasks();
    view.rerender(
      <Root>
        <Mount shown={false} />
      </Root>
    );
    view.rerender(
      <Root>
        <Mount shown />
      </Root>
    );
    await flushMicrotasks();
    expect(calls).toBe(1);

    pending.resolve(response(1, { replace: true, events: [assistant("assistant-1", "transferred")] }));
    await waitFor(() => expect(current?.phase).toBe("ready"));
    expect(view.getByTestId("resource").textContent).toContain("transferred");
  });

  test("progress ticks coalesce to one latest-wins rerun", async () => {
    const first = deferred<SubagentTranscript>();
    const second = deferred<SubagentTranscript>();
    const calls: Array<{ afterRevision?: number }> = [];
    installBridge((params) => {
      calls.push(params);
      return calls.length === 1 ? first.promise : second.promise;
    });
    const view = render(
      <Root>
        <TranscriptProbe tick={1} />
      </Root>
    );
    await flushMicrotasks();
    view.rerender(
      <Root>
        <TranscriptProbe tick={2} />
      </Root>
    );
    view.rerender(
      <Root>
        <TranscriptProbe tick={3} />
      </Root>
    );
    await flushMicrotasks();
    expect(calls).toHaveLength(1);

    first.resolve(response(1, { replace: true, events: [assistant("assistant-1", "one")] }));
    await waitFor(() => expect(calls).toHaveLength(2));
    expect(calls[1].afterRevision).toBe(1);
    second.resolve(response(1));
    await flushMicrotasks();
    expect(calls).toHaveLength(2);
  });

  test("running to settled queues exactly one terminal refresh", async () => {
    const first = deferred<SubagentTranscript>();
    const final = deferred<SubagentTranscript>();
    let calls = 0;
    installBridge(() => {
      calls += 1;
      return calls === 1 ? first.promise : final.promise;
    });
    const view = render(
      <Root>
        <TranscriptProbe tick={8} />
      </Root>
    );
    await flushMicrotasks();
    view.rerender(
      <Root>
        <TranscriptProbe />
      </Root>
    );
    view.rerender(
      <Root>
        <TranscriptProbe />
      </Root>
    );
    await flushMicrotasks();
    expect(calls).toBe(1);

    first.resolve(response(1, { replace: true, events: [assistant("assistant-1", "partial")] }));
    await waitFor(() => expect(calls).toBe(2));
    final.resolve(response(2, { events: [assistant("assistant-2", "final")] }));
    await waitFor(() => expect(view.getByTestId("resource").textContent).toContain("final"));
    expect(calls).toBe(2);
  });

  test("reopening retries a terminal transcript that was previously missing", async () => {
    let calls = 0;
    installBridge(async () => {
      calls += 1;
      if (calls === 1) return response(1, { replace: true, missing: true });
      return response(2, {
        replace: true,
        events: [assistant("assistant-final", "appeared after terminal signal")]
      });
    });
    let current: TranscriptResource | undefined;
    const view = render(
      <Root>
        <TranscriptProbe capture={(value) => (current = value)} />
      </Root>
    );
    await waitFor(() => expect(current?.phase).toBe("missing"));

    view.rerender(
      <Root>
        <TranscriptProbe open={false} capture={(value) => (current = value)} />
      </Root>
    );
    view.rerender(
      <Root>
        <TranscriptProbe capture={(value) => (current = value)} />
      </Root>
    );

    await waitFor(() => expect(calls).toBe(2));
    await waitFor(() =>
      expect(view.getByTestId("resource").textContent).toContain("appeared after terminal signal")
    );
  });

  test("identity changes clear all prior state and ignore stale completions", async () => {
    const first = deferred<SubagentTranscript>();
    const second = deferred<SubagentTranscript>();
    installBridge((params) => (params.agentId === "agent-a" ? first.promise : second.promise));
    let current: TranscriptResource | undefined;
    const view = render(
      <Root>
        <TranscriptProbe
          target={{ workflowRunId: "wf-run", agentId: "agent-a" }}
          capture={(value) => (current = value)}
        />
      </Root>
    );
    first.resolve(response(1, {
      replace: true,
      events: [assistant("assistant-a", "agent A")],
      truncated: true,
      meta: { agentType: "old", description: "Agent A", spawnDepth: 3 }
    }));
    await waitFor(() => expect(current?.phase).toBe("ready"));

    view.rerender(
      <Root>
        <TranscriptProbe
          target={{ workflowRunId: "wf-run", agentId: "agent-b" }}
          capture={(value) => (current = value)}
        />
      </Root>
    );
    expect(current?.phase).toBe("loading");
    expect(current?.model).toBeUndefined();
    expect(current?.meta).toBeUndefined();
    expect(current?.truncated).toBe(false);
    expect(view.getByTestId("resource").textContent).not.toContain("agent A");

    second.resolve(response(1, { replace: true, events: [assistant("assistant-b", "agent B")] }));
    await waitFor(() => expect(view.getByTestId("resource").textContent).toContain("agent B"));
  });

  test("conversation generation resets reused target identities atomically", async () => {
    const nextConversation = deferred<SubagentTranscript>();
    let calls = 0;
    installBridge(() => {
      calls += 1;
      return calls === 1
        ? Promise.resolve(response(1, {
            replace: true,
            events: [assistant("old", "old conversation")],
            truncated: true,
            meta: { description: "Old agent", spawnDepth: 2 }
          }))
        : nextConversation.promise;
    });
    let current: TranscriptResource | undefined;
    function Conversation({ generation }: { generation: number }) {
      return (
        <CopyProvider dict={undefined}>
          <SubagentTranscriptResourceProvider generation={generation}>
            <TranscriptProbe
              target={{ taskId: "reused-task" }}
              capture={(value) => (current = value)}
            />
          </SubagentTranscriptResourceProvider>
        </CopyProvider>
      );
    }

    const view = render(<Conversation generation={0} />);
    await waitFor(() => expect(view.getByTestId("resource").textContent).toContain("old conversation"));
    view.rerender(<Conversation generation={1} />);
    expect(current?.phase).toBe("loading");
    expect(current?.model).toBeUndefined();
    expect(current?.meta).toBeUndefined();
    expect(current?.truncated).toBe(false);
    expect(view.getByTestId("resource").textContent).not.toContain("old conversation");
    await waitFor(() => expect(calls).toBe(2));

    nextConversation.resolve(
      response(2, { replace: true, events: [assistant("new", "new conversation")] })
    );
    await waitFor(() => expect(view.getByTestId("resource").textContent).toContain("new conversation"));
  });

  test("live frames arriving during a disk read prevent fallback hydration", async () => {
    const pending = deferred<SubagentTranscript>();
    installBridge(() => pending.promise);
    const liveModel = replayLines(fwdNestedFixture);
    const emptyModel: TranscriptModel = {
      ...liveModel,
      agentThreads: {
        ...liveModel.agentThreads,
        [FWD_OUTER_TOOL_USE_ID]: {
          ...liveModel.agentThreads[FWD_OUTER_TOOL_USE_ID],
          blocks: [],
          hasLiveFrames: undefined
        }
      }
    };
    const hydrated: ProtocolLine[][] = [];

    function Chat({ model }: { model: TranscriptModel }) {
      const scrollRef = useRef<HTMLDivElement>(null);
      return (
        <AgentChatView
          thread={model.agentThreads[FWD_OUTER_TOOL_USE_ID]}
          relays={[]}
          scrollRef={scrollRef}
          onHydrate={(_toolUseId, events) => hydrated.push(events)}
        />
      );
    }

    const view = render(
      <Root>
        <Chat model={emptyModel} />
      </Root>
    );
    await flushMicrotasks();
    view.rerender(
      <Root>
        <Chat model={liveModel} />
      </Root>
    );
    pending.resolve(response(1, { replace: true, events: [assistant("disk", "stale disk")] }));
    await flushMicrotasks();
    expect(hydrated).toEqual([]);
    expect(view.container.textContent).not.toContain("stale disk");
  });
});

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { taskBridgeStub } from "./bridgeStub";
import { act, cleanup, render, waitFor } from "@testing-library/react";
import type { HarnessBridge, StartParams } from "../src/bridge";
import { HarnessBridgeError } from "../src/bridge";
import type { ProtocolLine } from "../src/protocol/types";
import { copyDefaults } from "../src/copyKeys";
import { rewindHistory, REWIND_UUIDS } from "../src/dev/fixtures/rewind";
import { HarnessStore } from "../src/model/store";
import { defaultDarkTheme } from "../src/ui/theme";
import { useHarness, type HarnessController } from "../src/ui/useHarness";

afterEach(cleanup);

interface Script {
  calls: string[];
  startParams: StartParams[];
  restartParams: StartParams[];
  rewindParams: Array<{ userMessageUuid: string; restoreFiles: boolean; resumeAtUuid?: string }>;
  openedInNewPane: string[];
  /** A live process refuses a plain `start`, exactly as the controller does. */
  running: boolean;
  failStart?: string;
  failRestart?: string;
  restartImpl?: (params: StartParams) => Promise<{ runId: string }>;
  failSetModel?: string;
  failInterrupt?: string;
  /** `rewind_files` refuses while the conversation rewind still succeeds. */
  restoreFails?: boolean;
  restoreSessionId?: string;
  historyEvents?: ProtocolLine[];
  loadHistory?: (sessionId: string) => Promise<{ events: ProtocolLine[]; truncated: boolean }>;
  cachedModels?: boolean;
  contextUsagePercentages?: number[];
  contextUsageCalls: number;
}

function makeBridge(script: Script): HarnessBridge {
  const note = (name: string) => script.calls.push(name);
  const noop = async () => {};
  return {
    async context() {
      note("context");
      return {
        panelId: "p",
        theme: defaultDarkTheme,
        copy: { ...copyDefaults },
        cliStatus: { available: true, version: "2.1.233" },
        restore: script.restoreSessionId
          ? { sessionId: script.restoreSessionId, model: "sonnet" }
          : undefined,
        cachedModels: script.cachedModels
          ? [{ value: "sonnet", resolvedModel: "claude-sonnet-5", displayName: "Sonnet 5" }]
          : undefined
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory({ sessionId }) {
      note(`loadSessionHistory:${sessionId}`);
      return script.loadHistory?.(sessionId) ?? {
        events: script.historyEvents ?? rewindHistory,
        truncated: false
      };
    },
    async start(params = {}) {
      note("start");
      script.startParams.push(params);
      if (script.failStart) {
        throw new HarnessBridgeError({ code: "start_failed", userMessage: script.failStart });
      }
      if (script.running) {
        throw new HarnessBridgeError({
          code: "session_already_running",
          userMessage: "A Claude session is already running in this pane."
        });
      }
      script.running = true;
      return { runId: "run-1" };
    },
    async restart(params = {}) {
      note("restart");
      script.restartParams.push(params);
      if (script.failRestart) {
        throw new HarnessBridgeError({ code: "start_failed", userMessage: script.failRestart });
      }
      if (script.restartImpl) return script.restartImpl(params);
      script.running = true;
      return { runId: "run-2" };
    },
    async openSessionInNewPane({ sessionId }) {
      script.openedInNewPane.push(sessionId);
    },
    async send() {
      note("send");
      return { sent: true };
    },
    interrupt: async () => {
      if (script.failInterrupt) throw new Error(script.failInterrupt);
    },
    cancelQueued: noop,
    stop: noop,
    setModel: async () => {
      note("setModel");
      if (script.failSetModel) throw new Error(script.failSetModel);
    },
    setPermissionMode: noop,
    respondPermission: noop,
    renameSession: noop,
    async getContextUsage() {
      const percentages = script.contextUsagePercentages ?? [0];
      const percentage = percentages[Math.min(script.contextUsageCalls, percentages.length - 1)];
      script.contextUsageCalls += 1;
      return { totalTokens: percentage * 2000, maxTokens: 200000, percentage };
    },
    async fileSuggestions() {
      return { paths: [] };
    },
    async pickFiles() {
      return { images: [], paths: [] };
    },
    openFile: noop,
    copyText: noop,
    async saveFile() {
      return { saved: false };
    },
    notify: noop,
    saveDraft: noop,
    async getBinarySetting() {
      return {};
    },
    async setBinaryPath() {
      return {};
    },
    async rewindPreview() {
      return { canRewind: true, filesChanged: ["/a"], insertions: 1, deletions: 1 };
    },
    async rewind(params) {
      note("rewind");
      script.rewindParams.push(params);
      // Whatever was asked for happened, unless the script says otherwise: the
      // half-failure is its own case, tested where it is the point.
      if (script.restoreFails) {
        return { runId: "run-3", filesRestored: false, reason: "no checkpoint" };
      }
      return { runId: "run-3", filesRestored: params.restoreFiles };
    },
    ...taskBridgeStub
  };
}

function script(overrides: Partial<Script> = {}): Script {
  return {
    calls: [],
    startParams: [],
    restartParams: [],
    rewindParams: [],
    openedInNewPane: [],
    running: false,
    contextUsageCalls: 0,
    ...overrides
  };
}

function Probe({ store, out }: { store: HarnessStore; out: { current?: HarnessController } }) {
  out.current = useHarness(store);
  return null;
}

async function mount(s: Script) {
  const store = new HarnessStore();
  window.supermuxHarnessMock = makeBridge(s);
  const out: { current?: HarnessController } = {};
  render(<Probe store={store} out={out} />);
  await flush();
  return { store, out };
}

async function flush() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 5));
  });
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

beforeEach(() => {
  delete window.supermuxHarnessMock;
});

/**
 * The reported failures: picking a session from the browser while a session was
 * running, and "New session" while one was running, both raised "A Claude
 * session is already running". `start` refuses by design; only `restart` tears
 * the old process down first.
 */
describe("swapping sessions never goes through start()", () => {
  test("resuming a session while one runs uses restart, not start", async () => {
    const s = script({ running: true });
    const { out } = await mount(s);

    await act(async () => {
      out.current!.restart("session-abc", false);
    });
    await flush();

    expect(s.calls).toContain("restart");
    expect(s.calls).not.toContain("start");
    expect(s.restartParams[0].resumeSessionId).toBe("session-abc");
  });

  test("it loads that session's history before restarting into it", async () => {
    const s = script({ running: true });
    const { out } = await mount(s);
    await act(async () => {
      out.current!.restart("session-abc", false);
    });
    await flush();
    expect(s.calls.indexOf("loadSessionHistory:session-abc")).toBeLessThan(
      s.calls.indexOf("restart")
    );
  });

  test("an older history load cannot override a newer session selection", async () => {
    const historyA = deferred<{ events: ProtocolLine[]; truncated: boolean }>();
    const historyB = deferred<{ events: ProtocolLine[]; truncated: boolean }>();
    const s = script({
      running: true,
      loadHistory: (sessionId) => (sessionId === "session-a" ? historyA.promise : historyB.promise)
    });
    const { out } = await mount(s);

    act(() => {
      out.current!.restart("session-a", false);
      out.current!.restart("session-b", false);
    });
    historyB.resolve({ events: [], truncated: false });
    await flush();
    historyA.resolve({ events: [], truncated: false });
    await flush();

    expect(s.restartParams.map((params) => params.resumeSessionId)).toEqual(["session-b"]);
  });

  test("a newer selection waits for an in-flight restart and then wins", async () => {
    const firstRestart = deferred<{ runId: string }>();
    const s = script({
      running: true,
      restartImpl: (params) =>
        params.resumeSessionId === "session-a"
          ? firstRestart.promise
          : Promise.resolve({ runId: "run-b" })
    });
    const { out } = await mount(s);

    act(() => out.current!.restart("session-a", false));
    await flush();
    expect(s.restartParams.map((params) => params.resumeSessionId)).toEqual(["session-a"]);

    act(() => out.current!.restart("session-b", false));
    await flush();
    expect(s.restartParams.map((params) => params.resumeSessionId)).toEqual(["session-a"]);

    firstRestart.resolve({ runId: "run-a" });
    await flush();
    expect(s.restartParams.map((params) => params.resumeSessionId)).toEqual([
      "session-a",
      "session-b"
    ]);
  });

  test("a failed history load does not restart under the previous transcript", async () => {
    const s = script({
      running: true,
      loadHistory: async () => {
        throw new Error("history unavailable");
      }
    });
    const { store, out } = await mount(s);
    const turnsBefore = store.getSnapshot().turns;

    act(() => {
      out.current!.restart("session-abc", false);
    });
    await flush();

    expect(s.restartParams).toHaveLength(0);
    expect(store.getSnapshot().turns).toEqual(turnsBefore);
  });

  test("fork travels with the resume", async () => {
    const s = script({ running: true });
    const { out } = await mount(s);
    await act(async () => {
      out.current!.restart("session-abc", true);
    });
    await flush();
    expect(s.restartParams[0].forkSession).toBe(true);
  });

  test("New Session restarts with NO resume id and clears the transcript", async () => {
    // Passing a session id here is what would make "New session" reopen the old
    // one; the native side must not fall back to the snapshot either.
    const s = script({ running: true, restoreSessionId: "old-session" });
    const { store, out } = await mount(s);
    expect(store.getSnapshot().turns.length).toBeGreaterThan(0);

    await act(async () => {
      out.current!.newSession();
    });
    await flush();

    // The pane's CURRENT mode travels with every start now — a New Session must
    // keep the mode the user is in rather than silently dropping to a default.
    expect(s.restartParams).toHaveLength(1);
    expect(s.restartParams[0].resumeSessionId).toBeUndefined();
    expect(s.restartParams[0].model).toBe(store.getSnapshot().session.model);
    expect(s.restartParams[0].effort).toBe(store.getSnapshot().session.effort);
    expect(s.restartParams[0].permissionMode).toBe(store.getSnapshot().session.permissionMode);
    expect(store.getSnapshot().turns).toEqual([]);
  });

  test("New Session carries the live session model and effort, and seeds them before restart resolves", async () => {
    const s = script({ running: true });
    const { store, out } = await mount(s);

    // The model came from the CLI init frame, not from the user's model picker.
    act(() => {
      store.receive([
        {
          kind: "protocol",
          line: {
            type: "system",
            subtype: "init",
            session_id: "live-session",
            model: "claude-opus-5"
          } as ProtocolLine
        }
      ]);
      store.flushNow();
      // Effort is session state too. Dispatching it directly deliberately bypasses
      // useHarness's old pendingModel ref, proving restart reads the authoritative
      // store rather than only choices made through this hook instance.
      store.dispatch({ kind: "setModel", model: "claude-opus-5", effort: "xhigh" });
    });

    act(() => {
      out.current!.newSession();
    });

    // Reset is synchronous: the empty composer must never render an unnamed
    // model while the native restart is still tearing the old process down.
    expect(store.getSnapshot().session.model).toBe("claude-opus-5");
    expect(store.getSnapshot().session.effort).toBe("xhigh");

    await flush();
    expect(s.restartParams[0].model).toBe("claude-opus-5");
    expect(s.restartParams[0].effort).toBe("xhigh");
  });

  test("a later init frame is authoritative over the model carried into New Session", async () => {
    const s = script({ running: true });
    const { store, out } = await mount(s);
    act(() => {
      store.receive([
        {
          kind: "protocol",
          line: {
            type: "system",
            subtype: "init",
            session_id: "old-session",
            model: "claude-opus-5"
          } as ProtocolLine
        }
      ]);
      store.flushNow();
    });

    act(() => {
      out.current!.newSession();
    });
    expect(store.getSnapshot().session.model).toBe("claude-opus-5");
    await flush();

    act(() => {
      store.receive([
        {
          kind: "protocol",
          line: {
            type: "system",
            subtype: "init",
            session_id: "new-session",
            model: "claude-sonnet-5"
          } as ProtocolLine
        }
      ]);
      store.flushNow();
    });

    expect(store.getSnapshot().session.model).toBe("claude-sonnet-5");
  });

  test("an init resolved id preserves effort selected for the same catalog model", async () => {
    const s = script({ cachedModels: true });
    const { store } = await mount(s);
    act(() => {
      store.dispatch({ kind: "setModel", model: "sonnet", effort: "xhigh" });
      store.receive([
        {
          kind: "protocol",
          line: {
            type: "system",
            subtype: "init",
            session_id: "new-session",
            model: "claude-sonnet-5"
          } as ProtocolLine
        }
      ]);
      store.flushNow();
    });

    expect(store.getSnapshot().session.model).toBe("claude-sonnet-5");
    expect(store.getSnapshot().session.effort).toBe("xhigh");
  });

  test("a successful restart clears a startFailed left by the previous attempt", async () => {
    const s = script({ failStart: "spawn claude ENOENT" });
    const { store, out } = await mount(s);

    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();
    expect(store.getSnapshot().startFailed).toBe(true);

    s.failStart = undefined;
    await act(async () => {
      out.current!.restart();
    });
    await flush();

    expect(store.getSnapshot().startFailed).toBeUndefined();
    expect(store.getSnapshot().runPhase).toBe("running");
  });

  test("a failed restart is reported rather than swallowed", async () => {
    const s = script({ failRestart: "claude exited immediately" });
    const { store, out } = await mount(s);
    await act(async () => {
      out.current!.restart();
    });
    await flush();
    expect(store.getSnapshot().startFailed).toBe(true);
    expect(store.getSnapshot().exitError).toBe("claude exited immediately");
  });

  test("sends are blocked while a restart is in flight", async () => {
    let release: (() => void) | undefined;
    const s = script();
    const bridge = makeBridge(s);
    const slow: HarnessBridge = {
      ...bridge,
      restart: async (params) => {
        s.calls.push("restart");
        s.restartParams.push(params ?? {});
        await new Promise<void>((resolve) => {
          release = resolve;
        });
        return { runId: "run-2" };
      }
    };
    const store = new HarnessStore();
    window.supermuxHarnessMock = slow;
    const out: { current?: HarnessController } = {};
    render(<Probe store={store} out={out} />);
    await flush();

    act(() => {
      out.current!.restart();
    });
    await flush();
    expect(out.current!.restarting).toBe(true);

    await act(async () => {
      release?.();
      await new Promise((resolve) => setTimeout(resolve, 5));
    });
    expect(out.current!.restarting).toBe(false);
  });
});

describe("continuity follows the pane's own session, not the snapshot", () => {
  test("a send after exit resumes the session the pane is actually on", async () => {
    // `system/init` moved the pane to a new session; the restore snapshot still
    // names the one the panel was serialized with. Resuming the snapshot
    // silently reopens an older conversation.
    const s = script({ restoreSessionId: "snapshot-session" });
    const { store, out } = await mount(s);
    act(() => {
      store.receive([
        {
          kind: "protocol",
          line: { type: "system", subtype: "init", session_id: "live-session" } as never
        }
      ]);
      store.flushNow();
    });

    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();

    expect(s.startParams[0].resumeSessionId).toBe("live-session");
  });

  test("a resumed session's init model wins over the previous session's explicit selection", async () => {
    const s = script({
      running: true,
      historyEvents: [
        {
          type: "system",
          subtype: "init",
          session_id: "target-session",
          model: "claude-sonnet-5"
        } as ProtocolLine
      ]
    });
    const { store, out } = await mount(s);
    await act(async () => {
      out.current!.setModel("claude-opus-5", "max");
    });

    await act(async () => {
      out.current!.restart("target-session", false);
    });
    await flush();

    expect(store.getSnapshot().session.model).toBe("claude-sonnet-5");
    expect(store.getSnapshot().session.effort).toBeUndefined();
    expect(s.restartParams[0].model).toBe("claude-sonnet-5");
    expect(s.restartParams[0].effort).toBeUndefined();
  });

  test("before any init frame it falls back to the restore snapshot", async () => {
    // A pane restored from a panel snapshot whose history has not been replayed
    // yet: the snapshot is all there is to go on, and it is the right answer.
    const s = script({ restoreSessionId: "snapshot-session" });
    const bridge = makeBridge(s);
    window.supermuxHarnessMock = {
      ...bridge,
      loadSessionHistory: async () => ({ events: [], truncated: false })
    };
    const store = new HarnessStore();
    const out: { current?: HarnessController } = {};
    render(<Probe store={store} out={out} />);
    await flush();
    expect(store.getSnapshot().session.sessionId).toBeUndefined();

    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();
    expect(s.startParams[0].resumeSessionId).toBe("snapshot-session");
  });
});

describe("a model picked before the first start rides along with it", () => {
  test("the selection becomes the first start's model parameter", async () => {
    // There is no process to push `set_model` to yet; dropping the choice on
    // the floor made the menu look decorative until after the first send.
    const s = script();
    const { out } = await mount(s);
    await act(async () => {
      out.current!.setModel("opus", "high");
    });
    expect(s.calls).not.toContain("setModel");

    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();

    expect(s.startParams[0].model).toBe("opus");
    expect(s.startParams[0].effort).toBe("high");
  });

  test("once a process exists the change is pushed live instead", async () => {
    const s = script();
    const { out } = await mount(s);
    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();
    await act(async () => {
      out.current!.setModel("haiku");
    });
    expect(s.calls).toContain("setModel");
  });

  test("a rejected live model change leaves the authoritative model selected", async () => {
    const s = script({ failSetModel: "unsupported model" });
    const { store, out } = await mount(s);
    await act(async () => {
      out.current!.send("hello", []);
    });
    act(() => {
      store.dispatch({ kind: "setModel", model: "sonnet" });
      out.current!.setModel("opus", "high");
    });
    await flush();

    expect(store.getSnapshot().session.model).toBe("sonnet");
    expect(store.getSnapshot().session.modelPickPending).toBeUndefined();
  });

  test("a failed queue-clearing interrupt keeps locally queued messages", async () => {
    const s = script({ failInterrupt: "interrupt failed" });
    const { store, out } = await mount(s);
    act(() => {
      store.dispatch({ kind: "localSend", uuid: "active", text: "in flight", atMs: 1 });
      store.dispatch({ kind: "localSend", uuid: "queued", text: "keep me", atMs: 2 });
      out.current!.interrupt(true);
    });
    await flush();

    expect(store.getSnapshot().queued.map((message) => message.uuid)).toEqual(["queued"]);
  });
});

describe("a cached catalog reaches the model menu without a running process", () => {
  test("context.cachedModels lands in the model", async () => {
    const s = script({ cachedModels: true });
    const { store } = await mount(s);
    expect(store.getSnapshot().cachedModels?.[0].value).toBe("sonnet");
  });

  test("a pushed modelCatalog event lands too", async () => {
    const s = script();
    const { store } = await mount(s);
    act(() => {
      store.receive([
        { kind: "modelCatalog", models: [{ value: "opus", displayName: "Opus 5" }] }
      ]);
      store.flushNow();
    });
    expect(store.getSnapshot().cachedModels?.[0].displayName).toBe("Opus 5");
  });

  test("clearing the conversation does not empty the model menu", async () => {
    // The catalog is a property of the BINARY, not of the conversation.
    const s = script({ cachedModels: true });
    const { store, out } = await mount(s);
    await act(async () => {
      out.current!.newSession();
    });
    await flush();
    expect(store.getSnapshot().cachedModels?.[0].value).toBe("sonnet");
  });
});

describe("rewind drives the bridge and the transcript together", () => {
  test("it sends the target uuid and the PREVIOUS message as the resume point", async () => {
    const s = script({ restoreSessionId: "rewind-session-7712" });
    const { store, out } = await mount(s);
    expect(store.getSnapshot().turns.length).toBe(4);

    await act(async () => {
      await out.current!.rewind(
        { uuid: REWIND_UUIDS.third, text: "third", resumeAtUuid: REWIND_UUIDS.second },
        true
      );
    });

    expect(s.rewindParams).toEqual([
      {
        userMessageUuid: REWIND_UUIDS.third,
        restoreFiles: true,
        resumeAtUuid: REWIND_UUIDS.second
      }
    ]);
  });

  test("the transcript truncates and the composer is refilled, but only after it succeeds", async () => {
    const s = script({ restoreSessionId: "rewind-session-7712" });
    const { store, out } = await mount(s);

    await act(async () => {
      await out.current!.rewind(
        { uuid: REWIND_UUIDS.third, text: "Rename the resume helper", resumeAtUuid: REWIND_UUIDS.second },
        true
      );
    });

    expect(store.getSnapshot().turns.map((t) => t.userUuid)).toEqual([
      REWIND_UUIDS.first,
      REWIND_UUIDS.second
    ]);
    expect(out.current!.draft).toBe("Rename the resume helper");
  });

  test("a failed rewind leaves the transcript alone", async () => {
    // Truncating first would show less conversation than the session still has.
    const s = script({ restoreSessionId: "rewind-session-7712" });
    const bridge = makeBridge(s);
    window.supermuxHarnessMock = {
      ...bridge,
      rewind: async () => {
        throw new HarnessBridgeError({ code: "rewind_failed", userMessage: "no checkpoint" });
      }
    };
    const store = new HarnessStore();
    const out: { current?: HarnessController } = {};
    render(<Probe store={store} out={out} />);
    await flush();
    const before = store.getSnapshot().turns.length;

    await act(async () => {
      await out
        .current!.rewind({ uuid: REWIND_UUIDS.third, text: "third" }, true)
        .catch(() => undefined);
    });

    expect(store.getSnapshot().turns.length).toBe(before);
    expect(out.current!.draft).toBe("");
  });
});

describe("opening a session in another pane", () => {
  test("goes to the bridge rather than replacing this pane's run", async () => {
    const s = script({ running: true });
    const { out } = await mount(s);
    await act(async () => {
      out.current!.openSessionInNewPane("session-xyz");
    });
    await flush();
    expect(s.openedInNewPane).toEqual(["session-xyz"]);
    expect(s.calls).not.toContain("restart");
  });
});

describe("live context usage", () => {
  test("refreshes after an assistant step while the turn is still streaming", async () => {
    const s = script({ contextUsagePercentages: [10, 25] });
    const { store, out } = await mount(s);

    act(() => {
      store.receive([{ kind: "runStarted", runId: "run-live-context" }]);
      store.flushNow();
      store.dispatch({
        kind: "localSend",
        uuid: "first-prompt",
        text: "first",
        atMs: 1000
      });
      store.receive([
        {
          kind: "protocol",
          line: {
            type: "assistant",
            uuid: "assistant-complete",
            message: {
              role: "assistant",
              content: [{ type: "text", text: "done" }]
            }
          }
        },
        {
          kind: "protocol",
          line: {
            type: "result",
            uuid: "result-complete",
            subtype: "success",
            is_error: false,
            result: "done"
          }
        }
      ]);
      store.flushNow();
    });

    await waitFor(() => expect(out.current?.model.contextUsage?.percentage).toBe(10));

    act(() => {
      store.dispatch({
        kind: "localSend",
        uuid: "second-prompt",
        text: "second",
        atMs: 2000
      });
      store.receive([
        {
          kind: "protocol",
          line: {
            type: "assistant",
            uuid: "assistant-live",
            message: {
              role: "assistant",
              content: [
                {
                  type: "tool_use",
                  id: "tool-live",
                  name: "Read",
                  input: { file_path: "/tmp/example" }
                }
              ]
            }
          }
        }
      ]);
      store.flushNow();
    });

    expect(store.getSnapshot().turns.at(-1)?.state).toBe("streaming");
    await waitFor(() => expect(out.current?.model.contextUsage?.percentage).toBe(25));
    expect(s.contextUsageCalls).toBe(2);
  });
});

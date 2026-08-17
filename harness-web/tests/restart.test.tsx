import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { taskBridgeStub } from "./bridgeStub";
import { act, cleanup, render } from "@testing-library/react";
import type { HarnessBridge, StartParams } from "../src/bridge";
import { HarnessBridgeError } from "../src/bridge";
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
  /** `rewind_files` refuses while the conversation rewind still succeeds. */
  restoreFails?: boolean;
  restoreSessionId?: string;
  cachedModels?: boolean;
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
      return { events: rewindHistory, truncated: false };
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
    interrupt: noop,
    cancelQueued: noop,
    stop: noop,
    setModel: async () => {
      note("setModel");
    },
    setPermissionMode: noop,
    respondPermission: noop,
    renameSession: noop,
    async getContextUsage() {
      return { totalTokens: 0, maxTokens: 200000, percentage: 0 };
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

    expect(s.restartParams).toEqual([
      { resumeSessionId: undefined, model: "sonnet", effort: undefined, permissionMode: undefined }
    ]);
    expect(store.getSnapshot().turns).toEqual([]);
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
    store.receive([
      {
        kind: "protocol",
        line: { type: "system", subtype: "init", session_id: "live-session" } as never
      }
    ]);
    store.flushNow();

    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();

    expect(s.startParams[0].resumeSessionId).toBe("live-session");
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
    store.receive([
      { kind: "modelCatalog", models: [{ value: "opus", displayName: "Opus 5" }] }
    ]);
    store.flushNow();
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

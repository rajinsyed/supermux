import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act, cleanup, render } from "@testing-library/react";
import type { HarnessBridge, StartParams } from "../src/bridge";
import { HarnessBridgeError } from "../src/bridge";
import { copyDefaults } from "../src/copyKeys";
import { rewindHistory } from "../src/dev/fixtures/rewind";
import { HarnessStore } from "../src/model/store";
import { defaultDarkTheme } from "../src/ui/theme";
import { useHarness, type HarnessController } from "../src/ui/useHarness";

afterEach(cleanup);
beforeEach(() => {
  delete window.supermuxHarnessMock;
});

const noop = async () => {};

interface Script {
  calls: string[];
  startParams: StartParams[];
  failRestart?: string;
}

function makeBridge(script: Script): HarnessBridge {
  return {
    async context() {
      script.calls.push("context");
      return {
        panelId: "p",
        theme: defaultDarkTheme,
        copy: { ...copyDefaults },
        cliStatus: { available: true },
        restore: { sessionId: "snapshot-session" }
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory({ sessionId }) {
      script.calls.push(`load:${sessionId}`);
      return { events: rewindHistory, truncated: false };
    },
    async start(params = {}) {
      script.calls.push("start");
      script.startParams.push(params);
      return { runId: "run-start" };
    },
    async restart(params = {}) {
      script.calls.push("restart");
      if (script.failRestart) {
        throw new HarnessBridgeError({ code: "x", userMessage: script.failRestart });
      }
      script.startParams.push(params);
      return { runId: "run-restart" };
    },
    openSessionInNewPane: noop,
    async send() {
      script.calls.push("send");
      return { sent: true };
    },
    interrupt: noop,
    cancelQueued: noop,
    stop: noop,
    setModel: noop,
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
      return { canRewind: true, filesChanged: [], insertions: 0, deletions: 0 };
    },
    async rewind() {
      return { runId: "run-rewind" };
    }
  };
}

function Probe({ store, out }: { store: HarnessStore; out: { current?: HarnessController } }) {
  out.current = useHarness(store);
  return null;
}

async function flush(ms = 15) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

async function mount(script: Script) {
  window.supermuxHarnessMock = makeBridge(script);
  const store = new HarnessStore();
  const out: { current?: HarnessController } = {};
  render(<Probe store={store} out={out} />);
  await flush();
  return { store, out };
}

const script = (overrides: Partial<Script> = {}): Script => ({
  calls: [],
  startParams: [],
  ...overrides
});

/**
 * "New session" has to mean the pane is on NO session. Two separate places kept
 * pointing it back at the old one, and both of them turn the very next send into
 * a resume of the conversation the user just cleared.
 */
describe("New Session actually leaves the old session behind", () => {
  test("the live session id is cleared, so a later send does not resume it", async () => {
    const s = script({ failRestart: "spawn failed" });
    const { store, out } = await mount(s);
    // The pane is on a live session from its init frame.
    await act(async () => {
      store.receive([
        {
          kind: "protocol",
          line: { type: "system", subtype: "init", session_id: "live-session" } as never
        }
      ]);
      store.flushNow();
    });
    expect(store.getSnapshot().session.sessionId).toBe("live-session");

    await act(async () => {
      out.current!.newSession();
    });
    await flush();
    expect(store.getSnapshot().session.sessionId).toBeUndefined();

    // The restart failed, so the pane is exited and the next send starts it. That
    // start must not carry the discarded session.
    s.failRestart = undefined;
    await act(async () => {
      out.current!.send("fresh", []);
    });
    await flush();
    const started = s.startParams[s.startParams.length - 1];
    expect(started.resumeSessionId).toBeUndefined();
  });

  test("a later context reload does not replay the snapshot over the cleared pane", async () => {
    // `harness.context` is re-read on ordinary events — closing the binary
    // dialog is one — and it still carries the panel's serialized session.
    const s = script();
    const { store, out } = await mount(s);
    expect(store.getSnapshot().turns.length).toBeGreaterThan(0);

    await act(async () => {
      out.current!.newSession();
    });
    await flush();
    expect(store.getSnapshot().turns).toEqual([]);

    await act(async () => {
      out.current!.reloadContext();
    });
    await flush();

    expect(store.getSnapshot().turns).toEqual([]);
    expect(s.calls.filter((c) => c === "load:snapshot-session").length).toBe(1);
  });
});

describe("resuming another session is not undone by the snapshot either", () => {
  test("a context reload after a deliberate resume keeps the chosen session", async () => {
    const s = script();
    const { store, out } = await mount(s);

    await act(async () => {
      out.current!.restart("session-X", false);
    });
    await flush();
    s.calls.length = 0;

    await act(async () => {
      out.current!.reloadContext();
    });
    await flush();

    // The reload must not drag the pane back to the serialized session: no
    // second history load, and the next start still targets the chosen one.
    expect(s.calls).not.toContain("load:snapshot-session");

    await act(async () => {
      store.receive([{ kind: "runExited", runId: "run-restart", status: 0 }]);
      store.flushNow();
    });
    await act(async () => {
      out.current!.send("carry on", []);
    });
    await flush();
    const started = s.startParams[s.startParams.length - 1];
    expect(started.resumeSessionId).not.toBe("snapshot-session");
  });
});

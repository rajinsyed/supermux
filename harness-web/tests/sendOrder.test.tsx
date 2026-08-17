import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act, cleanup, render } from "@testing-library/react";
import type { HarnessBridge } from "../src/bridge";
import { copyDefaults } from "../src/copyKeys";
import { HarnessStore } from "../src/model/store";
import { defaultDarkTheme } from "../src/ui/theme";
import { useHarness, type HarnessController } from "../src/ui/useHarness";

afterEach(cleanup);
beforeEach(() => {
  delete window.supermuxHarnessMock;
});

function Probe({ store, out }: { store: HarnessStore; out: { current?: HarnessController } }) {
  out.current = useHarness(store);
  return null;
}

async function flush(ms = 400) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

interface Wire {
  sent: string[];
  startDelayMs: number;
  startCount: number;
}

const noop = async () => {};

function makeBridge(wire: Wire): HarnessBridge {
  return {
    async context() {
      return {
        panelId: "p",
        theme: defaultDarkTheme,
        copy: { ...copyDefaults },
        cliStatus: { available: true, version: "2.1.233" }
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory() {
      return { events: [], truncated: false };
    },
    async start() {
      wire.startCount += 1;
      // A real spawn is not instant. This delay is the whole point: the first
      // send waits on it, and anything that does not queue behind it overtakes.
      await new Promise((resolve) => setTimeout(resolve, wire.startDelayMs));
      return { runId: "run-1" };
    },
    async restart() {
      return { runId: "run-2" };
    },
    openSessionInNewPane: noop,
    async send({ text }) {
      wire.sent.push(text);
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
      return { runId: "run-3" };
    }
  };
}

async function mount(wire: Wire) {
  const store = new HarnessStore();
  window.supermuxHarnessMock = makeBridge(wire);
  const out: { current?: HarnessController } = {};
  render(<Probe store={store} out={out} />);
  await flush(10);
  return { store, out };
}

/**
 * The reducer keeps the on-screen queue FIFO, but the transcript is only half
 * the story: what the CLI actually receives is the order `bridge.send` is
 * CALLED in. The first send of a pane has to wait for the process to spawn,
 * while every later one has nothing to wait for — so a message typed second
 * reached the CLI first and was answered first, which is exactly the
 * "jumped ahead of the chips" report.
 */
describe("messages reach the bridge in the order they were typed", () => {
  test("a send typed during the first start does not overtake it on the wire", async () => {
    const wire: Wire = { sent: [], startDelayMs: 120, startCount: 0 };
    const { out } = await mount(wire);

    await act(async () => {
      out.current!.send("first", []);
      out.current!.send("second", []);
    });
    await flush();

    expect(wire.sent).toEqual(["first", "second"]);
  });

  test("a burst of sends keeps its order even when the process is already up", async () => {
    const wire: Wire = { sent: [], startDelayMs: 60, startCount: 0 };
    const { out } = await mount(wire);

    await act(async () => {
      out.current!.send("one", []);
    });
    await flush();
    expect(wire.sent).toEqual(["one"]);

    await act(async () => {
      out.current!.send("two", []);
      out.current!.send("three", []);
      out.current!.send("four", []);
    });
    await flush();

    expect(wire.sent).toEqual(["one", "two", "three", "four"]);
    // One process, not four: the guard against re-spawning must survive the
    // serialization.
    expect(wire.startCount).toBe(1);
  });

  test("a send after the process exited starts it again instead of vanishing", async () => {
    // `started` is a latch, and an exit does not unlatch it: the pane kept
    // accepting messages and forwarding them to a process that was gone.
    const wire: Wire = { sent: [], startDelayMs: 5, startCount: 0 };
    const { store, out } = await mount(wire);

    await act(async () => {
      out.current!.send("before", []);
    });
    await flush();
    expect(wire.startCount).toBe(1);

    store.receive([{ kind: "runExited", runId: "run-1", status: 0 }]);
    store.flushNow();
    expect(store.getSnapshot().runPhase).toBe("exited");

    await act(async () => {
      out.current!.send("after", []);
    });
    await flush();

    expect(wire.startCount).toBe(2);
    expect(wire.sent).toEqual(["before", "after"]);
  });

  test("a send into a pane whose process is ALREADY live does not try to start a second one", async () => {
    // The pane was restored onto a process the native side already had running,
    // so the web layer never called `start` itself and its latch is false — but
    // `runStarted` told it a process is live. Calling `start` anyway is refused
    // with "A Claude session is already running in this pane", which is the exact
    // error this round exists to remove, resurfacing from the other direction.
    const wire: Wire = { sent: [], startDelayMs: 5, startCount: 0 };
    const { store, out } = await mount(wire);

    store.receive([{ kind: "runStarted", runId: "run-native-1" }]);
    store.flushNow();
    expect(store.getSnapshot().runPhase).toBe("running");

    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();

    expect(wire.startCount).toBe(0);
    expect(wire.sent).toEqual(["hello"]);
    expect(store.getSnapshot().startFailed).toBeUndefined();
  });

  test("the local transcript order matches the wire order", async () => {
    const wire: Wire = { sent: [], startDelayMs: 120, startCount: 0 };
    const { store, out } = await mount(wire);

    await act(async () => {
      out.current!.send("alpha", []);
      out.current!.send("beta", []);
    });
    await flush();

    const model = store.getSnapshot();
    const onScreen = model.turns
      .map((turn) => turn.userText)
      .concat(model.queued.map((q) => q.text))
      .filter(Boolean);
    expect(onScreen).toEqual(wire.sent);
  });
});

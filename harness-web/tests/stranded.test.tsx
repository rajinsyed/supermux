import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { taskBridgeStub } from "./bridgeStub";
import { act, cleanup, render } from "@testing-library/react";
import type { HarnessBridge } from "../src/bridge";
import { copyDefaults } from "../src/copyKeys";
import { HarnessStore } from "../src/model/store";
import {
  applyEvent,
  applyLine,
  applyLocalAction,
  createIndex,
  createModel
} from "../src/model/transcript";
import type { TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { StatusStrip } from "../src/ui/status/StatusStrip";
import { defaultDarkTheme } from "../src/ui/theme";
import { useHarness, type HarnessController } from "../src/ui/useHarness";

afterEach(cleanup);
beforeEach(() => {
  delete window.supermuxHarnessMock;
});

const ix = () => createIndex();

function send(
  model: TranscriptModel,
  index: ReturnType<typeof createIndex>,
  uuid: string,
  text: string,
  atMs: number
): TranscriptModel {
  return applyLocalAction(model, index, { kind: "localSend", uuid, text, atMs }, atMs);
}

let frame = 0;
function assistantLine(): ProtocolLine {
  frame += 1;
  return {
    type: "assistant",
    message: { id: `m${frame}`, role: "assistant", content: [{ type: "text", text: "hi" }] },
    uuid: `asst-${frame}`
  } as ProtocolLine;
}

/**
 * The queue lives inside the CLI process. When that process dies the messages it
 * was holding die with it, but the local chips used to survive — and the NEXT
 * run's first frame promotes queued[0] onto its turn. The result is a turn
 * labelled with one user's message and answered from a different one.
 */
describe("a dead run does not hand its queue to the next one", () => {
  test("an exit moves the queue aside instead of leaving it to be mis-promoted", () => {
    const index = ix();
    let model = createModel();
    model = send(model, index, "u1", "first", 1000);
    model = send(model, index, "u2", "second", 2000);
    expect(model.queued.map((q) => q.text)).toEqual(["second"]);

    model = applyEvent(model, index, { kind: "runExited", runId: "r1", status: 1 }, 3000);
    expect(model.queued).toEqual([]);
    // Not discarded: the user typed it, so it is held for re-send.
    expect(model.stranded.map((q) => q.text)).toEqual(["second"]);

    // The next run's first frame must NOT title its turn with the stale message.
    model = applyEvent(model, index, { kind: "runStarted", runId: "r2" }, 4000);
    model = applyLocalAction(model, index, { kind: "takeStranded" }, 4000);
    model = send(model, index, "u2", "second", 4100);
    model = applyLine(model, index, assistantLine(), 5000);
    expect(model.turns.map((t) => t.userText)).toEqual(["first", "second"]);
  });

  test("a start that never came up strands its queue rather than dropping it", () => {
    const index = ix();
    let model = createModel();
    model = send(model, index, "u1", "first", 1000);
    model = send(model, index, "u2", "second", 2000);
    model = applyLocalAction(model, index, { kind: "startFailed", error: "enoent" }, 3000);
    expect(model.queued).toEqual([]);
    expect(model.stranded.map((q) => q.text)).toEqual(["second"]);
  });

  test("cancelling a stranded chip really cancels it", () => {
    const index = ix();
    let model = createModel();
    model = send(model, index, "u1", "first", 1000);
    model = send(model, index, "u2", "second", 2000);
    model = applyEvent(model, index, { kind: "runExited", runId: "r1", status: 1 }, 3000);
    model = applyLocalAction(model, index, { kind: "cancelQueued", uuid: "u2" }, 4000);
    expect(model.stranded).toEqual([]);
  });

  test("the transcript reset a Restart performs does not eat the typed text", () => {
    // Restart replaces the transcript, and the reset used to take the unanswered
    // messages with it — so the chips that survived the crash vanished on the
    // very click meant to recover them, and nothing was ever re-sent.
    const index = ix();
    let model = createModel();
    model = send(model, index, "u1", "first", 1000);
    model = send(model, index, "u2", "second", 2000);
    model = applyEvent(model, index, { kind: "runExited", runId: "r1", status: 1 }, 3000);
    model = applyLocalAction(model, index, { kind: "reset" }, 4000);
    expect(model.stranded.map((q) => q.text)).toEqual(["second"]);
  });

  test("interrupt-with-cancel clears the stranded list too", () => {
    const index = ix();
    let model = createModel();
    model = send(model, index, "u1", "first", 1000);
    model = send(model, index, "u2", "second", 2000);
    model = applyEvent(model, index, { kind: "runExited", runId: "r1", status: 1 }, 3000);
    model = applyLocalAction(model, index, { kind: "clearQueued" }, 4000);
    expect(model.stranded).toEqual([]);
  });
});

/**
 * Replayed history stops wherever the recording stopped. A session that died
 * while Claude was working replays a turn that never closes, and nothing in the
 * live stream will ever close it — so the next run's output was filed under the
 * previous prompt, and its activity flags left a fresh pane claiming to think.
 */
describe("a new run never inherits the previous one's open turn", () => {
  test("a turn left streaming by replayed history is settled when a run starts", () => {
    const index = ix();
    let model = createModel();
    model = send(model, index, "u1", "unfinished when the process died", 1000);
    expect(model.turns[0].state).toBe("streaming");

    model = applyEvent(model, index, { kind: "runStarted", runId: "r2" }, 2000);
    expect(model.turns[0].state).not.toBe("streaming");

    // The new run's first frame must therefore open a turn of its own rather
    // than appending its answer to the stale one.
    model = applyLine(model, index, assistantLine(), 3000);
    expect(model.turns.length).toBe(2);
  });

  test("activity read off replayed history does not survive into the new run", () => {
    const index = ix();
    let model = createModel();
    model = {
      ...model,
      activity: { sessionState: "running", status: "requesting", thinkingTokens: 400 }
    };
    model = applyEvent(model, index, { kind: "runStarted", runId: "r2" }, 2000);
    expect(model.activity.sessionState).toBe("idle");
    expect(model.activity.status).toBeNull();
  });
});

describe("the status strip counts messages that are waiting on the next run", () => {
  test("stranded messages are never reported as Ready", () => {
    const index = ix();
    let model = createModel();
    model = send(model, index, "u1", "first", 1000);
    model = send(model, index, "u2", "second", 2000);
    model = applyEvent(model, index, { kind: "runExited", runId: "r1", status: 0 }, 3000);
    // Exited outranks the queue in the strip, so read the count directly: what
    // must never happen is an idle pane printing Ready over waiting chips.
    const idle = { ...model, runPhase: "idle" as const };
    const { container } = render(
      <CopyProvider dict={undefined}>
        <StatusStrip
          model={idle}
          runPhase={idle.runPhase}
          activity={idle.activity}
          cliUnavailable={false}
          onRestart={() => {}}
        />
      </CopyProvider>
    );
    const text = container.textContent ?? "";
    expect(text).not.toContain(copyDefaults["supermux.harness.status.idle"]);
    expect(text).toContain("1");
  });
});

const noop = async () => {};

function Probe({ store, out }: { store: HarnessStore; out: { current?: HarnessController } }) {
  out.current = useHarness(store);
  return null;
}

async function flush(ms = 20) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

function makeBridge(wire: { sent: string[]; starts: number }): HarnessBridge {
  return {
    async context() {
      return {
        panelId: "p",
        theme: defaultDarkTheme,
        copy: { ...copyDefaults },
        cliStatus: { available: true }
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory() {
      return { events: [], truncated: false };
    },
    async start() {
      wire.starts += 1;
      return { runId: `run-${wire.starts}` };
    },
    async restart() {
      return { runId: "run-restart" };
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
      return { runId: "run-rewind", filesRestored: true };
    },
    ...taskBridgeStub
  };
}

describe("stranded messages are re-sent, in order, once a run is back up", () => {
  test("they reach the wire again rather than being silently lost", async () => {
    const wire = { sent: [] as string[], starts: 0 };
    window.supermuxHarnessMock = makeBridge(wire);
    const store = new HarnessStore();
    const out: { current?: HarnessController } = {};
    render(<Probe store={store} out={out} />);
    await flush();

    await act(async () => {
      out.current!.send("first", []);
      out.current!.send("second", []);
      out.current!.send("third", []);
    });
    await flush();
    expect(wire.sent).toEqual(["first", "second", "third"]);

    // The process dies holding "second" and "third" unanswered.
    await act(async () => {
      store.receive([{ kind: "runExited", runId: "run-1", status: 1 }]);
      store.flushNow();
    });
    expect(store.getSnapshot().stranded.map((q) => q.text)).toEqual(["second", "third"]);

    await act(async () => {
      store.receive([{ kind: "runStarted", runId: "run-2" }]);
      store.flushNow();
    });
    await flush();

    expect(wire.sent).toEqual(["first", "second", "third", "second", "third"]);
    expect(store.getSnapshot().stranded).toEqual([]);
  });

  /**
   * The crash boundary. Everything stranded was typed BEFORE the exit, so
   * anything typed after it belongs behind them — on the wire, not merely in the
   * chip strip. The re-send used to wait for `runStarted`, while a message typed
   * in the gap had nothing to wait for and went straight out: it reached the CLI
   * first and was answered first, under a queue strip still listing the stranded
   * chips ahead of it. That is the same "a later message jumped the line" report
   * the send chain was built to end, arriving through the one door the chain did
   * not cover.
   */
  test("a message typed between the exit and the restart lands BEHIND the stranded ones", async () => {
    const wire = { sent: [] as string[], starts: 0 };
    window.supermuxHarnessMock = makeBridge(wire);
    const store = new HarnessStore();
    const out: { current?: HarnessController } = {};
    render(<Probe store={store} out={out} />);
    await flush();

    await act(async () => {
      out.current!.send("first", []);
      out.current!.send("second", []);
      out.current!.send("third", []);
    });
    await flush();
    expect(wire.sent).toEqual(["first", "second", "third"]);

    await act(async () => {
      store.receive([{ kind: "runExited", runId: "run-1", status: 1 }]);
      store.flushNow();
    });
    expect(store.getSnapshot().stranded.map((q) => q.text)).toEqual(["second", "third"]);

    // The gap: the process is down, no run has started, and the user types.
    await act(async () => {
      out.current!.send("typed after the crash", []);
    });
    await flush();

    // The stranded pair, in their original order, then the new one.
    expect(wire.sent.slice(3)).toEqual(["second", "third", "typed after the crash"]);
    expect(store.getSnapshot().stranded).toEqual([]);
  });

  test("the on-screen order after a crash-gap send matches the delivery order", async () => {
    // Half the original report was that the transcript and the CLI disagreed
    // about order, so asserting the wire alone leaves the visible half
    // unguarded. The comparison is against each message's LAST delivery: a
    // stranded message is legitimately on the wire twice — once into the process
    // that died holding it, once into the run that answers it — and only the
    // second delivery is the one the transcript is describing.
    const wire = { sent: [] as string[], starts: 0 };
    window.supermuxHarnessMock = makeBridge(wire);
    const store = new HarnessStore();
    const out: { current?: HarnessController } = {};
    render(<Probe store={store} out={out} />);
    await flush();

    await act(async () => {
      out.current!.send("first", []);
      out.current!.send("second", []);
    });
    await flush();
    await act(async () => {
      store.receive([{ kind: "runExited", runId: "run-1", status: 1 }]);
      store.flushNow();
    });
    await act(async () => {
      out.current!.send("third", []);
    });
    await flush();

    const model = store.getSnapshot();
    const onScreen = model.turns
      .map((turn) => turn.userText)
      .concat(model.queued.map((q) => q.text))
      .filter((text): text is string => Boolean(text));
    const delivered = onScreen.slice().sort((a, b) => wire.sent.lastIndexOf(a) - wire.sent.lastIndexOf(b));
    expect(onScreen).toEqual(delivered);
    expect(onScreen).toEqual(["first", "second", "third"]);
  });

  test("New Session is the one path that throws them away instead", async () => {
    // An empty pane is the whole point of New Session, so unanswered messages
    // must NOT be resurrected into it.
    const wire = { sent: [] as string[], starts: 0 };
    window.supermuxHarnessMock = makeBridge(wire);
    const store = new HarnessStore();
    const out: { current?: HarnessController } = {};
    render(<Probe store={store} out={out} />);
    await flush();

    await act(async () => {
      out.current!.send("first", []);
      out.current!.send("second", []);
    });
    await flush();
    await act(async () => {
      store.receive([{ kind: "runExited", runId: "run-1", status: 1 }]);
      store.flushNow();
    });
    expect(store.getSnapshot().stranded.length).toBe(1);

    await act(async () => {
      out.current!.newSession();
    });
    await flush();

    expect(store.getSnapshot().stranded).toEqual([]);
    expect(wire.sent).toEqual(["first", "second"]);
  });
});

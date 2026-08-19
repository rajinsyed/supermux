import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act, cleanup, render } from "@testing-library/react";
import { taskBridgeStub } from "./bridgeStub";
import type { HarnessBridge, StartParams } from "../src/bridge";
import type { EffortLevel, ModelDescriptor, ProtocolLine } from "../src/protocol/types";
import { copyDefaults } from "../src/copyKeys";
import {
  activeModelFor,
  adoptSessionModel,
  baseModelId,
  createIndex,
  effectiveEffort,
  emptySession,
  resolveModel,
  sameModelId
} from "../src/model/helpers";
import { applyLine, applyLocalAction, createModel } from "../src/model/transcript";
import { HarnessStore } from "../src/model/store";
import { defaultDarkTheme } from "../src/ui/theme";
import { useHarness, type HarnessController } from "../src/ui/useHarness";

afterEach(cleanup);
beforeEach(() => {
  delete window.supermuxHarnessMock;
});

/**
 * The dogfood round's two model-state bugs, pinned with the REAL rows from the
 * user's binary (a live `initialize` response) and the REAL frame shapes a live
 * probe of that binary produced:
 *
 *   `--model 'opus[1m]'` → init reports `"claude-opus-5[1m]"` → the assistant
 *   frames stamp `message.model: "claude-opus-5"` — three spellings of ONE
 *   model, and any strict-equality comparison between them is wrong.
 */
const CATALOG: ModelDescriptor[] = [
  {
    value: "default",
    resolvedModel: "claude-opus-5[1m]",
    displayName: "Default (recommended)",
    supportsEffort: true,
    supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]
  },
  {
    value: "opus[1m]",
    resolvedModel: "claude-opus-5[1m]",
    displayName: "Opus (1M context)",
    supportsEffort: true,
    supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]
  },
  {
    value: "claude-fable-5[1m]",
    resolvedModel: "claude-fable-5",
    displayName: "Fable",
    supportsEffort: true,
    supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]
  },
  {
    value: "sonnet",
    resolvedModel: "claude-sonnet-5",
    displayName: "Sonnet",
    supportsEffort: true,
    supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]
  },
  {
    value: "gpt-5.6-sol",
    resolvedModel: "gpt-5.6-sol",
    displayName: "GPT 5.6 Sol",
    supportsEffort: true,
    supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]
  }
];

let seq = 0;
const uid = (p: string) => `${p}-${(seq += 1).toString(16)}`;

/** Exactly what the composer trigger prints (ModelMenu.tsx). */
function triggerLabel(store: HarnessStore): string {
  const m = store.getSnapshot();
  const row = resolveModel(m.session, m.cachedModels);
  return row?.displayName ?? m.session.model ?? "Model";
}

function triggerEffort(store: HarnessStore): EffortLevel | undefined {
  const m = store.getSnapshot();
  const row = resolveModel(m.session, m.cachedModels);
  return effectiveEffort(row, m.session.effort, m.session.defaultEffort);
}

const initLine = (model: string, sessionId = uid("s")): ProtocolLine =>
  ({ type: "system", subtype: "init", session_id: sessionId, model, uuid: uid("i") }) as ProtocolLine;

const messageStart = (model: string): ProtocolLine =>
  ({
    type: "stream_event",
    uuid: uid("se"),
    session_id: "live",
    parent_tool_use_id: null,
    event: { type: "message_start", message: { id: uid("msg"), model } }
  }) as unknown as ProtocolLine;

const diskUser = (text: string): ProtocolLine =>
  ({
    type: "user",
    message: { role: "user", content: text },
    parent_tool_use_id: null,
    session_id: "resumed",
    uuid: uid("u"),
    timestamp: "2026-08-18T19:21:15.611Z"
  }) as ProtocolLine;

/** The shape of the user's real JSONL records: resolved API id + effort stamp. */
const diskAssistant = (model: string, effort?: string): ProtocolLine =>
  ({
    type: "assistant",
    message: { id: uid("m"), model, role: "assistant", content: [{ type: "text", text: "answer" }] },
    parent_tool_use_id: null,
    session_id: "resumed",
    uuid: uid("a"),
    timestamp: "2026-08-18T19:22:29.105Z",
    effort
  }) as ProtocolLine;

/* =========================================================================
   Bug 2 unit layer — one identity helper, used by every matcher.
   ========================================================================= */

describe("bug 2: a wire model id resolves to its catalog row across the [1m] suffix", () => {
  test("baseModelId strips only a trailing bracket suffix", () => {
    expect(baseModelId("claude-opus-5[1m]")).toBe("claude-opus-5");
    expect(baseModelId("opus[1m]")).toBe("opus");
    expect(baseModelId("claude-opus-5")).toBe("claude-opus-5");
    expect(baseModelId("gpt-5.6-sol")).toBe("gpt-5.6-sol");
  });

  test("sameModelId matches the three spellings of one model", () => {
    expect(sameModelId("claude-opus-5", "claude-opus-5[1m]")).toBe(true);
    expect(sameModelId("claude-fable-5", "claude-fable-5[1m]")).toBe(true);
    expect(sameModelId("claude-opus-5", "claude-sonnet-5")).toBe(false);
  });

  test("the assistant frames' bare API id finds the CONCRETE catalog row", () => {
    // "claude-opus-5" matches neither "opus[1m]" nor "claude-opus-5[1m]" by
    // equality — this was the exact display regression: the picker printed the
    // slug the moment a message was sent.
    const row = activeModelFor({ models: CATALOG, model: "claude-opus-5" });
    expect(row?.displayName).toBe("Opus (1M context)");
  });

  test("the init frame's suffixed resolved id prefers the named row over the default alias", () => {
    // Both "default" and "opus[1m]" resolve to "claude-opus-5[1m]"; the alias
    // row lists first but does not NAME the model.
    const row = activeModelFor({ models: CATALOG, model: "claude-opus-5[1m]" });
    expect(row?.displayName).toBe("Opus (1M context)");
  });

  test("Fable's inverted suffix (value carries [1m], resolvedModel does not) still matches", () => {
    const row = activeModelFor({ models: CATALOG, model: "claude-fable-5" });
    expect(row?.displayName).toBe("Fable");
  });

  test("a genuinely unknown wire model still displays its raw id — the honest fallback", () => {
    const session = { ...emptySession(), model: "claude-nonexistent-9" };
    expect(resolveModel(session, CATALOG)).toBeUndefined();
    // ModelMenu then prints session.model itself.
  });

  test("adoptSessionModel keeps the carried effort when the wire spells the same model differently", () => {
    const session = { ...emptySession(), model: "opus[1m]", effort: "high" as EffortLevel };
    const adopted = adoptSessionModel(session, CATALOG, "claude-opus-5");
    expect(adopted.model).toBe("claude-opus-5");
    expect(adopted.effort).toBe("high");
  });

  test("adoptSessionModel still drops effort on a REAL model change", () => {
    const session = { ...emptySession(), model: "opus[1m]", effort: "high" as EffortLevel };
    const adopted = adoptSessionModel(session, CATALOG, "claude-sonnet-5");
    expect(adopted.model).toBe("claude-sonnet-5");
    expect(adopted.effort).toBeUndefined();
  });
});

/* =========================================================================
   Bug 2 reducer layer — the send-time frames must not rename the picker.
   ========================================================================= */

describe("bug 2: sending a message never renames the picker to a slug", () => {
  function pickedOpusPane() {
    const index = createIndex();
    let m = createModel();
    m = applyLocalAction(m, index, { kind: "cachedModels", models: CATALOG }, 0);
    m = applyLocalAction(
      m,
      index,
      { kind: "sessionDefaults", model: "gpt-5.6-sol", effort: "xhigh" },
      0
    );
    m = applyLine(m, index, initLine("claude-opus-5[1m]", "live"), 0);
    return { index, m };
  }

  test("message_start stamping the bare API id keeps the display name", () => {
    const { index, m } = pickedOpusPane();
    expect(resolveModel(m.session, m.cachedModels)?.displayName).toBe("Opus (1M context)");
    const after = applyLine(m, index, messageStart("claude-opus-5"), 1);
    // 'Opus (1M context) Extra high' must NOT become 'claude-opus-5'.
    expect(resolveModel(after.session, after.cachedModels)?.displayName).toBe("Opus (1M context)");
  });

  test("message_start goes through adoption, so it keeps the carried effort too", () => {
    const index = createIndex();
    let m = createModel();
    m = applyLocalAction(m, index, { kind: "cachedModels", models: CATALOG }, 0);
    m = applyLocalAction(m, index, { kind: "setModel", model: "opus[1m]", effort: "high" }, 0);
    m = applyLine(m, index, messageStart("claude-opus-5"), 1);
    expect(m.session.effort).toBe("high");
    expect(resolveModel(m.session, m.cachedModels)?.displayName).toBe("Opus (1M context)");
  });

  test("a replayed session's disk records (bare API id + effort stamp) resolve to the row", () => {
    const index = createIndex();
    let m = createModel();
    m = applyLocalAction(m, index, { kind: "cachedModels", models: CATALOG }, 0);
    for (const line of [diskUser("earlier prompt"), diskAssistant("claude-opus-5", "xhigh")]) {
      m = applyLine(m, index, line, 1000);
    }
    m = applyLocalAction(m, index, { kind: "historyReplayed" }, 2000);
    expect(resolveModel(m.session, m.cachedModels)?.displayName).toBe("Opus (1M context)");
    expect(m.session.effort).toBe("xhigh");
  });

  test("a truly unknown streamed model is adopted and displayed raw — never hidden", () => {
    const { index, m } = pickedOpusPane();
    const after = applyLine(m, index, messageStart("claude-experimental-x"), 1);
    expect(after.session.model).toBe("claude-experimental-x");
    expect(resolveModel(after.session, after.cachedModels)).toBeUndefined();
  });
});

/* =========================================================================
   Bug 1 — the pick survives new session, the init frame, and in-flight frames.
   ========================================================================= */

interface Script {
  restartParams: StartParams[];
  startParams: StartParams[];
  setModelCalls: { model: string; effort?: string }[];
  historyEvents: ProtocolLine[];
  restore?: { sessionId: string; model?: string };
}

function makeBridge(script: Script): HarnessBridge {
  const noop = async () => {};
  return {
    async context() {
      return {
        panelId: "p",
        theme: defaultDarkTheme,
        copy: { ...copyDefaults },
        cliStatus: { available: true, version: "2.1.235" },
        restore: script.restore,
        cachedModels: CATALOG,
        // The user's ~/.claude/settings.json: model gpt-5.6-sol, effortLevel xhigh.
        defaults: { model: "gpt-5.6-sol", effort: "xhigh" }
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory() {
      return { events: script.historyEvents, truncated: false };
    },
    async start(params = {}) {
      script.startParams.push(params);
      return { runId: `run-${script.startParams.length}` };
    },
    async restart(params = {}) {
      script.restartParams.push(params);
      return { runId: `run-r${script.restartParams.length}` };
    },
    async openSessionInNewPane() {},
    async send() {
      return { sent: true };
    },
    interrupt: noop,
    cancelQueued: noop,
    stop: noop,
    setModel: async (p) => {
      script.setModelCalls.push(p);
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
      return { canRewind: true, filesChanged: [], insertions: 0, deletions: 0 };
    },
    async rewind() {
      return { runId: "run-3", filesRestored: false };
    },
    ...taskBridgeStub
  };
}

function Probe({ store, out }: { store: HarnessStore; out: { current?: HarnessController } }) {
  out.current = useHarness(store);
  return null;
}

async function mount(script: Script) {
  const store = new HarnessStore();
  window.supermuxHarnessMock = makeBridge(script);
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

describe("bug 1: the picker does not stay on the settings default", () => {
  test("the exact repro: defaults show, user picks another model, new session, init arrives — still the pick", async () => {
    const script: Script = { restartParams: [], startParams: [], setModelCalls: [], historyEvents: [] };
    const { store, out } = await mount(script);

    // Fresh pane: the settings default is the honest display.
    expect(triggerLabel(store)).toBe("GPT 5.6 Sol");
    expect(triggerEffort(store)).toBe("xhigh");

    // User picks another model in the menu.
    act(() => {
      out.current!.setModel("sonnet", undefined);
    });
    expect(triggerLabel(store)).toBe("Sonnet");

    // New session.
    await act(async () => {
      out.current!.newSession();
    });
    await flush();

    // The trigger-facing resolution shows the pick, synchronously and after.
    expect(triggerLabel(store)).toBe("Sonnet");
    // The restart carried the pick, so the CLI does not launch on the default.
    expect(script.restartParams[0]?.model).toBe("sonnet");

    // The init frame arrives with the resolved id — still the pick.
    act(() => {
      store.receive([{ kind: "protocol", line: initLine("claude-sonnet-5", "fresh") }]);
      store.flushNow();
    });
    expect(triggerLabel(store)).toBe("Sonnet");
  });

  test("an init frame reporting the SETTINGS model cannot revert an unconfirmed pick", async () => {
    // The race that produced "doesn't change even when i change it": the
    // restart's start params were built before the pick landed (or the pick
    // happened while no process could receive set_model), so the new process
    // came up on gpt-5.6-sol and its init frame overwrote the pick.
    const script: Script = { restartParams: [], startParams: [], setModelCalls: [], historyEvents: [] };
    const { store, out } = await mount(script);

    act(() => {
      out.current!.setModel("sonnet", undefined);
    });
    expect(triggerLabel(store)).toBe("Sonnet");

    // A process comes up on the settings model anyway (params raced the pick).
    act(() => {
      store.receive([
        { kind: "runStarted", runId: "raced-run" } as never,
        { kind: "protocol", line: initLine("gpt-5.6-sol", "raced") }
      ]);
      store.flushNow();
    });
    await flush();

    // The pick holds on screen…
    expect(triggerLabel(store)).toBe("Sonnet");
    // …and the hook reconciles by pushing set_model at the live process.
    expect(script.setModelCalls.map((c) => c.model)).toContain("sonnet");
  });

  test("a message_start from the old model's in-flight turn cannot revert a live pick either", async () => {
    const script: Script = { restartParams: [], startParams: [], setModelCalls: [], historyEvents: [] };
    const { store, out } = await mount(script);
    act(() => {
      store.receive([
        { kind: "runStarted", runId: "r1" } as never,
        { kind: "protocol", line: initLine("gpt-5.6-sol", "live") }
      ]);
      store.flushNow();
    });
    expect(triggerLabel(store)).toBe("GPT 5.6 Sol");

    act(() => {
      out.current!.setModel("opus[1m]", undefined);
    });
    expect(triggerLabel(store)).toBe("Opus (1M context)");

    // A frame the OLD model had already started streaming lands after the pick.
    act(() => {
      store.receive([{ kind: "protocol", line: messageStart("gpt-5.6-sol") }]);
      store.flushNow();
    });
    expect(triggerLabel(store)).toBe("Opus (1M context)");

    // The next turn's frames come from the picked model and confirm it —
    // spelled as the bare API id, which must neither revert nor slugify.
    act(() => {
      store.receive([{ kind: "protocol", line: messageStart("claude-opus-5") }]);
      store.flushNow();
    });
    expect(triggerLabel(store)).toBe("Opus (1M context)");

    // Confirmed: a later /model switch on the wire is adopted again.
    act(() => {
      store.receive([{ kind: "protocol", line: messageStart("claude-sonnet-5") }]);
      store.flushNow();
    });
    expect(triggerLabel(store)).toBe("Sonnet");
  });

  test("an explicit resume still adopts the resumed session's own model over a pending pick", async () => {
    // The latch must not outlive a deliberate move onto another session.
    const script: Script = {
      restartParams: [],
      startParams: [],
      setModelCalls: [],
      historyEvents: [diskUser("earlier"), diskAssistant("claude-opus-5", "xhigh")]
    };
    const { store, out } = await mount(script);
    act(() => {
      out.current!.setModel("sonnet", undefined);
    });
    await act(async () => {
      out.current!.restart("some-session", false);
    });
    await flush();
    expect(triggerLabel(store)).toBe("Opus (1M context)");
    expect(store.getSnapshot().session.effort).toBe("xhigh");
    // And the restart params carried the resumed session's model as a
    // catalog selector the CLI accepts.
    expect(script.restartParams[0]?.model).toBe("opus[1m]");
  });

  test("New Session with NO pick still restarts on the settings default and the init confirms it", async () => {
    const script: Script = { restartParams: [], startParams: [], setModelCalls: [], historyEvents: [] };
    const { store, out } = await mount(script);
    await act(async () => {
      out.current!.newSession();
    });
    await flush();
    expect(triggerLabel(store)).toBe("GPT 5.6 Sol");
    act(() => {
      store.receive([{ kind: "protocol", line: initLine("gpt-5.6-sol", "fresh2") }]);
      store.flushNow();
    });
    expect(triggerLabel(store)).toBe("GPT 5.6 Sol");
    expect(triggerEffort(store)).toBe("xhigh");
  });
});

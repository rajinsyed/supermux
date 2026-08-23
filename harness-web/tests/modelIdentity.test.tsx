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
  setModelImpl?(params: { model: string; effort?: string }): Promise<void>;
  historyEvents: ProtocolLine[];
  restore?: { sessionId: string; model?: string };
  /** context.defaults.lastUsed — the machine-wide last-used model. */
  lastUsed?: { model: string; effort?: EffortLevel };
  /** Omits settings-file defaults so context carries only lastUsed. */
  lastUsedOnly?: boolean;
  /**
   * When set, the RESTORED session's history load stalls until
   * `releaseHistory()` runs — the shape of the real bug: the user's restored
   * session file was 322KB and its parse+load landed seconds after the pane
   * opened, long after the user had picked a model.
   */
  holdRestoreHistory?: boolean;
  releaseHistory?: () => void;
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
        defaults: script.lastUsedOnly
          ? { lastUsed: script.lastUsed }
          : { model: "gpt-5.6-sol", effort: "xhigh", lastUsed: script.lastUsed }
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory(params) {
      // Only the restore-bootstrap load stalls; an explicit resume's own load
      // (a different session id) resolves immediately.
      if (script.holdRestoreHistory && params.sessionId === script.restore?.sessionId) {
        await new Promise<void>((resolve) => {
          script.releaseHistory = resolve;
        });
      }
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
      await script.setModelImpl?.(p);
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

  test("a failed reconciliation keeps the selection pending for a later run", async () => {
    const script: Script = {
      restartParams: [],
      startParams: [],
      setModelCalls: [],
      setModelImpl: async () => {
        throw new Error("set_model failed");
      },
      historyEvents: []
    };
    const { store, out } = await mount(script);
    act(() => out.current!.setModel("sonnet", undefined));
    expect(store.getSnapshot().session.modelPickPending).toBe(true);

    act(() => {
      store.receive([
        { kind: "runStarted", runId: "raced-run" } as never,
        { kind: "protocol", line: initLine("gpt-5.6-sol", "raced") }
      ]);
      store.flushNow();
    });
    await flush();

    expect(script.setModelCalls.map((call) => call.model)).toContain("sonnet");
    expect(store.getSnapshot().session.model).toBe("sonnet");
    expect(store.getSnapshot().session.modelPickPending).toBe(true);
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

/* =========================================================================
   Bug 1, round 2 — the RESTORE replay that lands seconds late.

   The dogfood repro after the first fix: the pick reached the CLI (the new
   session's JSONL shows claude-opus-5 + xhigh) but the trigger still said
   "GPT 5.6 Sol Extra high". The pane had a restore snapshot whose 322KB
   session file loaded asynchronously; its `.then` reset the conversation
   (clearing the pending-pick latch), replayed the OLD session — last
   assistant frame gpt-5.6-sol/xhigh — and `historyReplayed` adopted that over
   whatever the user had picked in the meantime.
   ========================================================================= */

describe("bug 1 round 2: a late restore replay cannot clobber the user's pick", () => {
  /** The old session's records: it ran gpt-5.6-sol at xhigh. */
  const oldSessionHistory = () => [
    diskUser("old prompt"),
    diskAssistant("gpt-5.6-sol", "xhigh")
  ];

  function restoredScript(): Script {
    return {
      restartParams: [],
      startParams: [],
      setModelCalls: [],
      historyEvents: oldSessionHistory(),
      restore: { sessionId: "restored-322kb", model: "gpt-5.6-sol" },
      holdRestoreHistory: true
    };
  }

  test("a pick made while the restore file is still loading survives the replay landing", async () => {
    const script = restoredScript();
    const { store, out } = await mount(script);

    // The load is in flight; the snapshot model shows meanwhile.
    expect(triggerLabel(store)).toBe("GPT 5.6 Sol");

    // The user picks another model before the file finishes parsing.
    act(() => {
      out.current!.setModel("opus[1m]", undefined);
    });
    expect(triggerLabel(store)).toBe("Opus (1M context)");

    // The replay lands late.
    await act(async () => {
      script.releaseHistory?.();
      await new Promise((resolve) => setTimeout(resolve, 5));
    });

    // Pre-fix: the replay reset cleared the latch and historyReplayed adopted
    // the OLD session's gpt-5.6-sol/xhigh — "still always gpt 5.6 sol extra
    // high no matter what". The pick must hold.
    expect(triggerLabel(store)).toBe("Opus (1M context)");
    expect(store.getSnapshot().session.effort).toBeUndefined();
  });

  test("newSession + confirming init while the restore load is in flight drops the stale replay wholesale", async () => {
    const script = restoredScript();
    const { store, out } = await mount(script);

    // User immediately starts a new session and picks a model.
    act(() => {
      out.current!.setModel("sonnet", undefined);
    });
    await act(async () => {
      out.current!.newSession();
    });
    await flush();
    expect(script.restartParams[0]?.model).toBe("sonnet");

    // The new process's init confirms the pick.
    act(() => {
      store.receive([{ kind: "protocol", line: initLine("claude-sonnet-5", "brand-new") }]);
      store.flushNow();
    });
    expect(triggerLabel(store)).toBe("Sonnet");

    // Now the OLD pane's history load finally resolves. snapshotRetired and
    // the generation check both say the pane moved on: nothing may change.
    const turnsBefore = store.getSnapshot().turns.length;
    await act(async () => {
      script.releaseHistory?.();
      await new Promise((resolve) => setTimeout(resolve, 5));
    });
    expect(triggerLabel(store)).toBe("Sonnet");
    expect(store.getSnapshot().session.sessionId).toBe("brand-new");
    // And the old transcript was not shoved back on screen either.
    expect(store.getSnapshot().turns.length).toBe(turnsBefore);
  });

  test("with NO pick, the late replay still restores normally — model, effort, transcript", async () => {
    const script = restoredScript();
    const { store } = await mount(script);
    expect(store.getSnapshot().turns.length).toBe(0);

    await act(async () => {
      script.releaseHistory?.();
      await new Promise((resolve) => setTimeout(resolve, 5));
    });

    // The untouched pane restores exactly as before the fix.
    expect(triggerLabel(store)).toBe("GPT 5.6 Sol");
    expect(store.getSnapshot().session.effort).toBe("xhigh");
    expect(store.getSnapshot().turns.length).toBeGreaterThan(0);
  });

  test("an explicit resume DURING the stalled restore load wins over the late replay", async () => {
    const script = restoredScript();
    const { store, out } = await mount(script);

    // The user resumes a different session while the restore file loads. The
    // resume's own history (a session that ran claude-opus-5/xhigh) resolves
    // immediately; only the restore load is stalled.
    script.historyEvents = [diskUser("other"), diskAssistant("claude-opus-5", "xhigh")];
    await act(async () => {
      out.current!.restart("another-session", false);
    });
    await flush();
    expect(triggerLabel(store)).toBe("Opus (1M context)");

    await act(async () => {
      script.releaseHistory?.();
      await new Promise((resolve) => setTimeout(resolve, 5));
    });
    // snapshotRetired: the stale restore reply is dropped.
    expect(triggerLabel(store)).toBe("Opus (1M context)");
  });
});

/* =========================================================================
   Item A — a new pane defaults to the LAST MODEL USED, not settings.json.

   "when i open a new pane the default model shown as selected is always gpt
   5.6 sol EH… it should change the default to the last model i used (in any
   session)". The native side records every model a session actually runs
   (start-with-model, set_model ack, init frame) into a machine-wide
   UserDefaults store and delivers it as context.defaults.lastUsed; the web
   layer ranks it above the settings-file default, below everything
   session-specific.
   ========================================================================= */

describe("item A: a fresh pane defaults to the machine-wide last-used model", () => {
  test("lastUsed outranks the settings default on a fresh pane — display AND start params", async () => {
    const script: Script = {
      restartParams: [],
      startParams: [],
      setModelCalls: [],
      historyEvents: [],
      lastUsed: { model: "opus[1m]", effort: "high" }
    };
    const { store, out } = await mount(script);

    // The trigger names the last-used model, not settings.json's gpt-5.6-sol.
    expect(triggerLabel(store)).toBe("Opus (1M context)");
    expect(triggerEffort(store)).toBe("high");

    // And a first send RUNS it too: display and reality must not diverge.
    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();
    expect(script.startParams[0]?.model).toBe("opus[1m]");
    expect(script.startParams[0]?.effort).toBe("high");
  });

  test("lastUsed still applies when no settings-file default exists", async () => {
    const script: Script = {
      restartParams: [],
      startParams: [],
      setModelCalls: [],
      historyEvents: [],
      lastUsed: { model: "opus[1m]", effort: "high" },
      lastUsedOnly: true
    };
    const { store, out } = await mount(script);

    expect(triggerLabel(store)).toBe("Opus (1M context)");
    expect(triggerEffort(store)).toBe("high");
    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();
    expect(script.startParams[0]?.model).toBe("opus[1m]");
    expect(script.startParams[0]?.effort).toBe("high");
  });

  test("with NO lastUsed recorded, the settings default still answers and rides the start", async () => {
    const script: Script = { restartParams: [], startParams: [], setModelCalls: [], historyEvents: [] };
    const { store, out } = await mount(script);
    expect(triggerLabel(store)).toBe("GPT 5.6 Sol");
    await act(async () => {
      out.current!.send("hello", []);
    });
    await flush();
    expect(script.startParams[0]?.model).toBe("gpt-5.6-sol");
    expect(script.startParams[0]?.effort).toBe("xhigh");
  });

  test("everything session-specific still outranks lastUsed", async () => {
    const script: Script = {
      restartParams: [],
      startParams: [],
      setModelCalls: [],
      historyEvents: [],
      lastUsed: { model: "opus[1m]" }
    };
    const { store, out } = await mount(script);

    // A user pick:
    act(() => {
      out.current!.setModel("sonnet", undefined);
    });
    expect(triggerLabel(store)).toBe("Sonnet");

    // A live init frame (spelled as a resolved id):
    act(() => {
      store.receive([{ kind: "protocol", line: initLine("claude-sonnet-5", "live-a") }]);
      store.flushNow();
    });
    expect(triggerLabel(store)).toBe("Sonnet");
  });

  test("a restore snapshot's model outranks lastUsed on a restored pane", async () => {
    const script: Script = {
      restartParams: [],
      startParams: [],
      setModelCalls: [],
      historyEvents: [diskUser("earlier"), diskAssistant("claude-sonnet-5", "high")],
      restore: { sessionId: "restored", model: "sonnet" },
      lastUsed: { model: "opus[1m]" }
    };
    const { store } = await mount(script);
    // The replayed session's own record wins (its history says sonnet).
    expect(triggerLabel(store)).toBe("Sonnet");
  });
});

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act, cleanup, render } from "@testing-library/react";
import { taskBridgeStub } from "./bridgeStub";
import type { HarnessBridge, StartParams } from "../src/bridge";
import type { ModelDescriptor, ProtocolLine } from "../src/protocol/types";
import { copyDefaults } from "../src/copyKeys";
import { resolveModel } from "../src/model/helpers";
import { HarnessStore } from "../src/model/store";
import { defaultDarkTheme } from "../src/ui/theme";
import { useHarness, type HarnessController } from "../src/ui/useHarness";

afterEach(cleanup);
beforeEach(() => {
  delete window.supermuxHarnessMock;
});

/**
 * Round-5 item 1: creating a new session showed a composer trigger that just
 * said "Model". The round-4 fix made `newSession` capture `session.model`
 * before reset — but on a RESTORED pane that had not yet started a process,
 * nothing had ever written `session.model`: the restored model lived only in
 * `context.restore.model`, and the REAL disk-history replay contains no
 * `system/init` frame (the native record mapper forwards only user/assistant
 * records — SupermuxHarnessSessionRecordMapper.protocolEvent returns nil for
 * everything else). The old tests passed because their history fixture
 * unrealistically included an init frame.
 *
 * These fixtures mirror reality: history is user/assistant records only.
 */

const CATALOG: ModelDescriptor[] = [
  { value: "default", displayName: "Default" },
  { value: "opus", resolvedModel: "claude-opus-5", displayName: "Opus 5" },
  { value: "sonnet", resolvedModel: "claude-sonnet-5", displayName: "Sonnet 5" }
];

let seq = 0;
const uid = (p: string) => `${p}-${(seq += 1).toString(16)}`;

function historyWithoutInit(model = "claude-opus-5"): ProtocolLine[] {
  return [
    {
      type: "user",
      message: { role: "user", content: "earlier prompt" },
      parent_tool_use_id: null,
      session_id: "restored-session",
      uuid: uid("u"),
      timestamp: "2026-08-18T19:21:15.611Z"
    } as ProtocolLine,
    {
      type: "assistant",
      message: {
        id: uid("m"),
        model,
        role: "assistant",
        content: [{ type: "text", text: "earlier answer" }]
      },
      parent_tool_use_id: null,
      session_id: "restored-session",
      uuid: uid("a"),
      timestamp: "2026-08-18T19:22:29.105Z"
    } as ProtocolLine
  ];
}

interface Script {
  restartParams: StartParams[];
  restore?: { sessionId: string; model?: string };
  historyEvents: ProtocolLine[];
  cachedModels?: ModelDescriptor[];
}

function makeBridge(script: Script): HarnessBridge {
  const noop = async () => {};
  return {
    async context() {
      return {
        panelId: "p",
        theme: defaultDarkTheme,
        copy: { ...copyDefaults },
        cliStatus: { available: true, version: "2.1.233" },
        restore: script.restore,
        cachedModels: script.cachedModels
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory() {
      return { events: script.historyEvents, truncated: false };
    },
    async start() {
      return { runId: "run-1" };
    },
    async restart(params = {}) {
      script.restartParams.push(params);
      return { runId: "run-2" };
    },
    async openSessionInNewPane() {},
    async send() {
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

/** Exactly what the composer trigger prints (ModelMenu.tsx line 107). */
function triggerLabel(store: HarnessStore): string | undefined {
  const model = store.getSnapshot();
  return resolveModel(model.session, model.cachedModels)?.displayName ?? model.session.model;
}

describe("round-5 item 1: the model trigger after New Session on a restored pane", () => {
  test("a restored pane's trigger is NEVER the empty placeholder — realistic history has no init frame", async () => {
    const { store } = await mount({
      restartParams: [],
      restore: { sessionId: "restored-session", model: "opus" },
      historyEvents: historyWithoutInit("claude-opus-5"),
      cachedModels: CATALOG
    });
    // The restored history replay carries no system/init record, so before the
    // fix session.model stayed undefined here and the trigger said "Model".
    expect(triggerLabel(store)).toBe("Opus 5");
  });

  test("New Session keeps that model in the trigger SYNCHRONOUSLY, before any init frame", async () => {
    const { store, out } = await mount({
      restartParams: [],
      restore: { sessionId: "restored-session", model: "opus" },
      historyEvents: historyWithoutInit("claude-opus-5"),
      cachedModels: CATALOG
    });

    act(() => {
      out.current!.newSession();
    });
    // The exact user-visible failure: immediately after New Session — no
    // restart resolved, no init frame — the trigger must still name a model.
    expect(triggerLabel(store)).toBe("Opus 5");

    await flush();
    expect(triggerLabel(store)).toBe("Opus 5");
  });

  test("the carried model rides the restart params too", async () => {
    const script: Script = {
      restartParams: [],
      restore: { sessionId: "restored-session", model: "opus" },
      historyEvents: historyWithoutInit("claude-opus-5"),
      cachedModels: CATALOG
    };
    const { out } = await mount(script);
    await act(async () => {
      out.current!.newSession();
    });
    await flush();
    expect(script.restartParams).toHaveLength(1);
    expect(script.restartParams[0].resumeSessionId).toBeUndefined();
    expect(script.restartParams[0].model).toBeDefined();
  });

  test("a pane with NO restore at all falls back to the catalog's default row, not the bare placeholder", async () => {
    const { store } = await mount({
      restartParams: [],
      historyEvents: [],
      cachedModels: CATALOG
    });
    expect(triggerLabel(store)).toBe("Default");
  });

  test("a stale snapshot model loses to what the replayed session actually ran", async () => {
    // The serialized snapshot claims sonnet; the replayed session's assistant
    // frames say claude-opus-5. The session's own record wins — this is the
    // "GPT 5.6 Sol"-class mismatch from the resume screenshot.
    const { store } = await mount({
      restartParams: [],
      restore: { sessionId: "restored-session", model: "sonnet" },
      historyEvents: historyWithoutInit("claude-opus-5"),
      cachedModels: CATALOG
    });
    await flush();
    expect(triggerLabel(store)).toBe("Opus 5");
  });

  test("an explicit resume adopts the resumed session's last-used model", async () => {
    const script: Script = {
      restartParams: [],
      historyEvents: historyWithoutInit("claude-sonnet-5"),
      cachedModels: CATALOG
    };
    const { store, out } = await mount(script);
    await act(async () => {
      out.current!.restart("some-other-session", false);
    });
    await flush();
    expect(triggerLabel(store)).toBe("Sonnet 5");
    // And the restart resumes it with that model rather than letting the CLI
    // fall back to the user's global default and silently switch the session.
    // Sent as the catalog SELECTOR — the id form `set_model`/`--model` accept —
    // not the resolved id the wire reported.
    expect(script.restartParams[0].model).toBe("sonnet");
  });
});

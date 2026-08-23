import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, render } from "@testing-library/react";
import type { HarnessBridge, StartParams } from "../src/bridge";
import { HarnessStore } from "../src/model/store";
import type { PermissionMode, ProtocolLine } from "../src/protocol/types";
import { defaultDarkTheme } from "../src/ui/theme";
import { useHarness, type HarnessController } from "../src/ui/useHarness";
import { taskBridgeStub } from "./bridgeStub";

interface Script {
  startParams: StartParams[];
  permissionModes: PermissionMode[];
  restorePermissionMode?: PermissionMode;
  setPermissionMode?(mode: PermissionMode): Promise<void>;
}

function makeBridge(script: Script): HarnessBridge {
  const noop = async () => {};
  return {
    async context() {
      return {
        panelId: "panel",
        theme: defaultDarkTheme,
        copy: {},
        cliStatus: { available: true },
        restore: script.restorePermissionMode
          ? {
              sessionId: "restored-session",
              permissionMode: script.restorePermissionMode
            }
          : undefined
      };
    },
    async listSessions() {
      return { sessions: [] };
    },
    async loadSessionHistory() {
      return { events: [], truncated: false };
    },
    async start(params = {}) {
      script.startParams.push(params);
      return { runId: "run-1" };
    },
    async restart() {
      return { runId: "run-2" };
    },
    openSessionInNewPane: noop,
    async send() {
      return { sent: true };
    },
    interrupt: noop,
    cancelQueued: noop,
    stop: noop,
    setModel: noop,
    async setPermissionMode({ mode }) {
      script.permissionModes.push(mode);
      await script.setPermissionMode?.(mode);
    },
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
      return { canRewind: false, filesChanged: [], insertions: 0, deletions: 0 };
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

async function mount(restorePermissionMode?: PermissionMode) {
  const script: Script = { startParams: [], permissionModes: [], restorePermissionMode };
  const store = new HarnessStore();
  window.supermuxHarnessMock = makeBridge(script);
  const out: { current?: HarnessController } = {};
  render(<Probe store={store} out={out} />);
  await flush();
  return { out, script, store };
}

async function flush() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 5));
  });
}

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

describe("permission mode state", () => {
  test("a brand-new pane starts in bypassPermissions", async () => {
    const { out, store } = await mount();

    expect(store.getSnapshot().session.permissionMode).toBe("bypassPermissions");
    expect(out.current!.model.session.permissionMode).toBe("bypassPermissions");
  });

  test("a user-picked mode is the mode used by ensureStarted", async () => {
    const { out, script, store } = await mount("plan");
    expect(store.getSnapshot().session.permissionMode).toBe("plan");

    act(() => out.current!.setPermissionMode("acceptEdits"));
    act(() => out.current!.send("hello", []));
    await flush();

    expect(script.permissionModes).toEqual(["acceptEdits"]);
    expect(script.startParams).toHaveLength(1);
    expect(script.startParams[0].permissionMode).toBe("acceptEdits");
    expect(store.getSnapshot().session.permissionMode).toBe("acceptEdits");
  });

  test("Shift+Tab can cycle from plan back to bypassPermissions", async () => {
    const { out, script, store } = await mount();

    act(() => out.current!.setPermissionMode("plan"));
    act(() => out.current!.cyclePermissionMode());
    await flush();

    expect(store.getSnapshot().session.permissionMode).toBe("bypassPermissions");
    expect(script.permissionModes).toEqual(["plan", "bypassPermissions"]);
  });

  test("a rejection from the previous run cannot roll back the replacement run", async () => {
    const { out, script, store } = await mount();
    act(() => out.current!.send("start", []));
    await flush();
    expect(store.getSnapshot().runId).toBe("run-1");

    let rejectOldMutation: (reason?: unknown) => void = () => undefined;
    script.setPermissionMode = () =>
      new Promise<void>((_resolve, reject) => {
        rejectOldMutation = reject;
      });
    act(() => out.current!.setPermissionMode("acceptEdits"));
    act(() => out.current!.restart());
    await flush();
    expect(store.getSnapshot().runId).toBe("run-2");

    await act(async () => {
      rejectOldMutation(new Error("old process exited"));
      await Promise.resolve();
    });
    await flush();

    expect(store.getSnapshot().session.permissionMode).toBe("acceptEdits");
  });

  test("the started mode echoed by init frames does not clobber the user pick", async () => {
    const { out, script, store } = await mount();

    act(() => out.current!.setPermissionMode("acceptEdits"));
    act(() => out.current!.send("hello", []));
    await flush();

    const startedMode = script.startParams[0].permissionMode;
    expect(startedMode).toBe("acceptEdits");
    const echoes: ProtocolLine[] = [
      {
        type: "system",
        subtype: "init",
        permissionMode: startedMode
      },
      {
        type: "control_response",
        response: { response: { current_permission_mode: startedMode } }
      }
    ] as ProtocolLine[];
    act(() => {
      store.receive(echoes.map((line) => ({ kind: "protocol", line })));
      store.flushNow();
    });

    expect(store.getSnapshot().session.permissionMode).toBe("acceptEdits");
  });
});

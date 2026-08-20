import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, render, waitFor } from "@testing-library/react";
import { installReceiver, type HarnessBridge } from "../src/bridge";
import { HarnessStore } from "../src/model/store";
import type {
  HarnessTheme,
  NativeEvent,
  NativeEventEnvelope,
  ProtocolLine
} from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { Elapsed } from "../src/ui/primitives/Elapsed";
import { PresentationVisibilityProvider } from "../src/ui/presentationVisibility";
import { TaskOutputView } from "../src/ui/tools/TaskOutput";

afterEach(() => {
  cleanup();
  delete window.supermuxHarness;
  delete window.supermuxHarnessMock;
  delete document.documentElement.dataset.supermuxPresentation;
});

function userEvent(id: string): NativeEvent {
  return {
    kind: "protocol",
    line: {
      type: "user",
      uuid: id,
      message: { role: "user", content: `message ${id}` }
    } as ProtocolLine
  };
}

function envelope(
  documentEpoch: string,
  firstSequence: number,
  events: NativeEvent[]
): NativeEventEnvelope {
  return {
    version: 1,
    documentEpoch,
    firstSequence,
    highestSequence: firstSequence + events.length - 1,
    events
  };
}

const theme: HarnessTheme = {
  isDark: true,
  pageBackground: "#000000",
  surfaceBackground: "#111111",
  surfaceElevatedBackground: "#222222",
  inputBackground: "#333333",
  border: "#444444",
  borderStrong: "#555555",
  text: "#ffffff",
  mutedText: "#bbbbbb",
  softText: "#999999",
  accent: "#cc8844",
  accentSoft: "#664422",
  danger: "#ff4444",
  shadow: "#00000088"
};

function visibility(
  store: HarnessStore,
  documentEpoch: string,
  visible: boolean,
  targetSequence: number
): void {
  store.setPresentationVisibility({ documentEpoch, visible, targetSequence });
}

describe("versioned native event reduction", () => {
  test("reduces synchronously while hidden without publishing React notifications", () => {
    const store = new HarnessStore();
    visibility(store, "document-one", false, 0);
    let rootNotifications = 0;
    let executionNotifications = 0;
    store.subscribe(() => {
      rootNotifications += 1;
    });
    store.subscribeExecution(() => {
      executionNotifications += 1;
    });

    const acknowledgement = store.receiveEnvelope(
      envelope("document-one", 1, [userEvent("hidden-turn")])
    );

    expect(acknowledgement).toEqual({
      version: 1,
      documentEpoch: "document-one",
      highestSequence: 1
    });
    expect(store.getSnapshot().turns).toHaveLength(1);
    expect(store.getTurnIds()).toEqual(["hidden-turn"]);
    expect(rootNotifications).toBe(0);
    expect(executionNotifications).toBe(1);
  });

  test("the document receiver acknowledges only reduced envelopes and deduplicates theme replay", () => {
    const store = new HarnessStore();
    let themePublications = 0;
    installReceiver({
      onBatch: store.receive,
      onEnvelope: store.receiveEnvelope,
      onPresentationVisibility: store.setPresentationVisibility,
      onTheme: () => {
        themePublications += 1;
      }
    });
    const receiver = window.supermuxHarness;
    expect(receiver).toBeDefined();
    const batch = envelope("document-one", 1, [{ kind: "theme", theme }]);

    expect(receiver?.receiveEnvelope(batch)).toEqual({
      version: 1,
      documentEpoch: "document-one",
      highestSequence: 1
    });
    expect(receiver?.receiveEnvelope(batch)?.highestSequence).toBe(1);
    expect(themePublications).toBe(1);
    expect(
      receiver?.receiveEnvelope({
        version: 1,
        documentEpoch: "document-one",
        firstSequence: 3,
        highestSequence: 3,
        events: [{ kind: "stderr", text: "gap" }]
      })
    ).toBeUndefined();
  });

  test("deduplicates an identical retry after it was reduced", () => {
    const store = new HarnessStore();
    let rootNotifications = 0;
    store.subscribe(() => {
      rootNotifications += 1;
    });
    const batch = envelope("document-one", 1, [userEvent("only-once")]);

    expect(store.receiveEnvelope(batch)?.highestSequence).toBe(1);
    expect(store.receiveEnvelope(batch)?.highestSequence).toBe(1);

    expect(store.getSnapshot().turns).toHaveLength(1);
    expect(rootNotifications).toBe(1);
  });

  test("rejects sequence gaps and stale document epochs", () => {
    const store = new HarnessStore();
    expect(store.receiveEnvelope(envelope("document-one", 1, [userEvent("first")]))).toBeDefined();

    expect(store.receiveEnvelope(envelope("document-one", 3, [userEvent("gap")]))).toBeUndefined();
    expect(store.receiveEnvelope(envelope("stale-document", 2, [userEvent("stale")]))).toBeUndefined();
    expect(store.getTurnIds()).toEqual(["first"]);
  });

  test("reveal waits for its target sequence then publishes one coherent update", () => {
    const store = new HarnessStore();
    visibility(store, "document-one", false, 0);
    store.receiveEnvelope(envelope("document-one", 1, [userEvent("first")]));
    let rootNotifications = 0;
    let presentationNotifications = 0;
    store.subscribe(() => {
      rootNotifications += 1;
    });
    store.subscribePresentation(() => {
      presentationNotifications += 1;
    });

    expect(
      store.setPresentationVisibility({
        documentEpoch: "document-one",
        visible: true,
        targetSequence: 2
      })
    ).toBe(false);
    expect(store.getPresentationVisible()).toBe(false);
    expect(rootNotifications).toBe(0);
    expect(presentationNotifications).toBe(0);

    store.receiveEnvelope(envelope("document-one", 2, [userEvent("second")]));
    expect(store.getPresentationVisible()).toBe(true);
    expect(
      store.setPresentationVisibility({
        documentEpoch: "document-one",
        visible: true,
        targetSequence: 2
      })
    ).toBe(true);
    expect(store.getTurnIds()).toEqual(["first", "second"]);
    expect(rootNotifications).toBe(1);
    expect(presentationNotifications).toBe(1);
  });

  test("several hidden batches collapse into one reveal publication", () => {
    const store = new HarnessStore();
    visibility(store, "document-one", false, 0);
    let rootNotifications = 0;
    store.subscribe(() => {
      rootNotifications += 1;
    });

    store.receiveEnvelope(envelope("document-one", 1, [userEvent("first")]));
    store.receiveEnvelope(envelope("document-one", 2, [userEvent("second")]));
    expect(rootNotifications).toBe(0);

    visibility(store, "document-one", true, 2);
    expect(rootNotifications).toBe(1);
    expect(store.getTurnIds()).toEqual(["first", "second"]);
  });
});

describe("presentation-only work", () => {
  test("publishes presentation visibility to the document for CSS animation pausing", () => {
    const store = new HarnessStore();
    render(
      <PresentationVisibilityProvider store={store}>
        <div />
      </PresentationVisibilityProvider>
    );

    act(() => visibility(store, "document-one", false, 0));
    expect(document.documentElement.dataset.supermuxPresentation).toBe("hidden");

    act(() => visibility(store, "document-one", true, 0));
    expect(document.documentElement.dataset.supermuxPresentation).toBe("visible");
  });

  test("elapsed labels pause while hidden and refresh immediately on reveal", () => {
    const store = new HarnessStore();
    const originalNow = Date.now;
    const originalSetInterval = window.setInterval;
    const originalClearInterval = window.clearInterval;
    let now = 1_000;
    let tick: (() => void) | undefined;
    Date.now = () => now;
    window.setInterval = ((handler: TimerHandler) => {
      if (typeof handler === "function") tick = handler as () => void;
      return 7_001;
    }) as typeof window.setInterval;
    window.clearInterval = (() => {}) as typeof window.clearInterval;

    try {
      const mounted = render(
        <PresentationVisibilityProvider store={store}>
          <CopyProvider dict={undefined}>
            <Elapsed startedAtMs={0} />
          </CopyProvider>
        </PresentationVisibilityProvider>
      );
      const initial = mounted.container.textContent;
      expect(initial).not.toBe("");

      act(() => visibility(store, "document-one", false, 0));
      now = 6_100;
      act(() => tick?.());
      expect(mounted.container.textContent).toBe(initial);

      act(() => visibility(store, "document-one", true, 0));
      expect(mounted.container.textContent).not.toBe(initial);
    } finally {
      Date.now = originalNow;
      window.setInterval = originalSetInterval;
      window.clearInterval = originalClearInterval;
    }
  });

  test("a settled task performs no hidden reads and one terminal refresh on reveal", async () => {
    const store = new HarnessStore();
    visibility(store, "document-one", false, 0);
    let reads = 0;
    window.supermuxHarnessMock = {
      async readTaskOutput() {
        reads += 1;
        return { text: "terminal output", truncated: false, missing: false };
      }
    } as unknown as HarnessBridge;

    render(
      <PresentationVisibilityProvider store={store}>
        <CopyProvider dict={undefined}>
          <TaskOutputView taskId="terminal-task" running={false} pollIntervalMs={5} />
        </CopyProvider>
      </PresentationVisibilityProvider>
    );
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(reads).toBe(0);

    act(() => visibility(store, "document-one", true, 0));
    await waitFor(() => expect(reads).toBe(1));
  });

  test("a running task cancels hidden polling and resumes with one immediate read", async () => {
    const store = new HarnessStore();
    const originalSetTimeout = window.setTimeout;
    const originalClearTimeout = window.clearTimeout;
    const timers = new Map<number, () => void>();
    let nextTimer = 9_000;
    let reads = 0;
    window.setTimeout = ((handler: TimerHandler, timeout?: number, ...args: unknown[]) => {
      if (timeout === 5 && typeof handler === "function") {
        nextTimer += 1;
        timers.set(nextTimer, handler as () => void);
        return nextTimer;
      }
      return originalSetTimeout(handler, timeout, ...args);
    }) as typeof window.setTimeout;
    window.clearTimeout = ((timer?: number) => {
      if (typeof timer === "number" && timers.delete(timer)) return;
      originalClearTimeout(timer);
    }) as typeof window.clearTimeout;
    window.supermuxHarnessMock = {
      async readTaskOutput() {
        reads += 1;
        return { text: `read ${reads}`, truncated: false, missing: false };
      }
    } as unknown as HarnessBridge;

    try {
      render(
        <PresentationVisibilityProvider store={store}>
          <CopyProvider dict={undefined}>
            <TaskOutputView taskId="running-task" running pollIntervalMs={5} />
          </CopyProvider>
        </PresentationVisibilityProvider>
      );
      await waitFor(() => expect(reads).toBe(1));
      await waitFor(() => expect(timers.size).toBe(1));

      act(() => visibility(store, "document-one", false, 0));
      expect(timers.size).toBe(0);

      act(() => visibility(store, "document-one", true, 0));
      await waitFor(() => expect(reads).toBe(2));
      await waitFor(() => expect(timers.size).toBe(1));
    } finally {
      window.setTimeout = originalSetTimeout;
      window.clearTimeout = originalClearTimeout;
    }
  });
});

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { getBridge, installReceiver, type HarnessBridge } from "../bridge";
import { HarnessStore } from "../model/store";
import type { ImageAttachment, TranscriptModel } from "../model/types";
import type {
  EffortLevel,
  HarnessContext,
  HarnessTheme,
  PermissionMode,
  SessionSummary
} from "../protocol/types";
import { defaultDarkTheme } from "./theme";

const MODE_CYCLE: PermissionMode[] = ["default", "acceptEdits", "plan"];

function uuidv4(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  return `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
  });
}

export interface HarnessController {
  model: TranscriptModel;
  theme: HarnessTheme;
  context?: HarnessContext;
  sessions: SessionSummary[];
  bridge: HarnessBridge;
  draft: string;
  setDraft(text: string): void;
  send(text: string, images: ImageAttachment[]): void;
  interrupt(cancelQueued: boolean): void;
  cancelQueued(uuid: string): void;
  restart(resumeSessionId?: string, fork?: boolean): void;
  setModel(model: string, effort?: EffortLevel): void;
  setPermissionMode(mode: PermissionMode): void;
  cyclePermissionMode(): void;
  refreshSessions(): void;
  refreshContext(): void;
  reloadContext(): void;
}

export function useHarness(store: HarnessStore): HarnessController {
  const model = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const [theme, setTheme] = useState<HarnessTheme>(defaultDarkTheme);
  const [context, setContext] = useState<HarnessContext | undefined>(undefined);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [draft, setDraftState] = useState("");
  const started = useRef(false);
  const bridge = useMemo(() => getBridge(), []);

  useEffect(() => {
    installReceiver({
      onBatch: (events) => store.receive(events),
      onTheme: (next) => setTheme(next)
    });
  }, [store]);

  const restoredSessionId = useRef<string | undefined>(undefined);

  const reloadContext = useCallback(() => {
    bridge
      .context()
      .then((next) => {
        setContext(next);
        setTheme(next.theme);
        if (next.draft) setDraftState(next.draft);
        const sessionId = next.restore?.sessionId;
        if (sessionId && restoredSessionId.current !== sessionId) {
          restoredSessionId.current = sessionId;
          bridge
            .loadSessionHistory({ sessionId })
            .then((result) => {
              store.dispatch({ kind: "reset" });
              store.receive(result.events.map((line) => ({ kind: "protocol" as const, line })));
            })
            .catch(() => undefined);
        }
      })
      .catch(() => undefined);
  }, [bridge, store]);

  const refreshSessions = useCallback(() => {
    bridge
      .listSessions({ limit: 40 })
      .then((result) => setSessions(result.sessions ?? []))
      .catch(() => undefined);
  }, [bridge]);

  const refreshContext = useCallback(() => {
    bridge
      .getContextUsage()
      .then((usage) => store.dispatch({ kind: "contextUsage", usage }))
      .catch(() => undefined);
  }, [bridge, store]);

  useEffect(() => {
    reloadContext();
    refreshSessions();
  }, [reloadContext, refreshSessions]);

  const lastTurnCount = useRef(0);
  useEffect(() => {
    const settled = model.turns.filter((turn) => turn.state !== "streaming").length;
    if (settled !== lastTurnCount.current) {
      lastTurnCount.current = settled;
      if (settled > 0) refreshContext();
    }
  }, [model.turns, refreshContext]);

  const setDraft = useCallback(
    (text: string) => {
      setDraftState(text);
      bridge.saveDraft({ text }).catch(() => undefined);
    },
    [bridge]
  );

  const ensureStarted = useCallback(
    async (resumeSessionId?: string, fork?: boolean) => {
      if (started.current && !resumeSessionId) return;
      started.current = true;
      await bridge
        .start({
          resumeSessionId: resumeSessionId ?? context?.restore?.sessionId,
          forkSession: fork,
          model: context?.restore?.model,
          permissionMode: context?.restore?.permissionMode
        })
        .catch((error: unknown) => {
          started.current = false;
          // A silent failure here leaves the composer accepting messages that go
          // nowhere; the exited state carries a Restart button.
          store.dispatch({
            kind: "startFailed",
            error: error instanceof Error ? error.message : undefined
          });
        });
    },
    [bridge, context, store]
  );

  const send = useCallback(
    (text: string, images: ImageAttachment[]) => {
      const uuid = uuidv4();
      store.dispatch({ kind: "localSend", uuid, text, images, atMs: Date.now() });
      setDraftState("");
      bridge.saveDraft({ text: "" }).catch(() => undefined);
      void ensureStarted().then(() =>
        bridge.send({ text, images: images.length > 0 ? images : undefined, uuid }).catch(() => undefined)
      );
    },
    [bridge, ensureStarted, store]
  );

  const interrupt = useCallback(
    (cancelQueued: boolean) => {
      bridge.interrupt({ cancelQueued }).catch(() => undefined);
    },
    [bridge]
  );

  const cancelQueued = useCallback(
    (uuid: string) => {
      store.dispatch({ kind: "cancelQueued", uuid });
      bridge.cancelQueued({ messageUuid: uuid }).catch(() => undefined);
    },
    [bridge, store]
  );

  const restart = useCallback(
    (resumeSessionId?: string, fork?: boolean) => {
      started.current = false;
      if (resumeSessionId) {
        bridge
          .loadSessionHistory({ sessionId: resumeSessionId })
          .then((result) => {
            store.dispatch({ kind: "reset" });
            store.receive(result.events.map((line) => ({ kind: "protocol" as const, line })));
          })
          .catch(() => undefined);
      }
      void ensureStarted(resumeSessionId, fork);
    },
    [bridge, ensureStarted, store]
  );

  const setModel = useCallback(
    (next: string, effort?: EffortLevel) => {
      store.dispatch({ kind: "setModel", model: next, effort });
      bridge.setModel({ model: next, effort }).catch(() => undefined);
    },
    [bridge, store]
  );

  const setPermissionMode = useCallback(
    (mode: PermissionMode) => {
      store.dispatch({ kind: "setPermissionMode", mode });
      bridge.setPermissionMode({ mode }).catch(() => undefined);
    },
    [bridge, store]
  );

  const cyclePermissionMode = useCallback(() => {
    const current = store.getSnapshot().session.permissionMode;
    const index = MODE_CYCLE.indexOf(current);
    setPermissionMode(MODE_CYCLE[(index + 1) % MODE_CYCLE.length]);
  }, [setPermissionMode, store]);

  return {
    model,
    theme,
    context,
    sessions,
    bridge,
    draft,
    setDraft,
    send,
    interrupt,
    cancelQueued,
    restart,
    setModel,
    setPermissionMode,
    cyclePermissionMode,
    refreshSessions,
    refreshContext,
    reloadContext
  };
}

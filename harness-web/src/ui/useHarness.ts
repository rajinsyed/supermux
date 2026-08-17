import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { getBridge, installReceiver, type HarnessBridge, type StartParams } from "../bridge";
import { HarnessStore } from "../model/store";
import type { ImageAttachment, TranscriptModel } from "../model/types";
import type {
  EffortLevel,
  HarnessContext,
  HarnessTheme,
  PermissionMode,
  RewindPreview,
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

export interface RewindRequest {
  /** The user message being rewound TO; its text goes back in the composer. */
  uuid: string;
  text: string;
  /** The uuid to resume the conversation AT — absent when this is message one. */
  resumeAtUuid?: string;
}

export interface HarnessController {
  model: TranscriptModel;
  theme: HarnessTheme;
  context?: HarnessContext;
  sessions: SessionSummary[];
  bridge: HarnessBridge;
  draft: string;
  /** A restart is in flight: the old process is down, the new one is not up. */
  restarting: boolean;
  setDraft(text: string): void;
  send(text: string, images: ImageAttachment[]): void;
  interrupt(cancelQueued: boolean): void;
  cancelQueued(uuid: string): void;
  restart(resumeSessionId?: string, fork?: boolean): void;
  newSession(): void;
  openSessionInNewPane(sessionId: string): void;
  rewindPreview(uuid: string): Promise<RewindPreview>;
  rewind(request: RewindRequest, restoreFiles: boolean): Promise<void>;
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
  const [restarting, setRestarting] = useState(false);
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
        // A catalog from a previous run of this binary, so the model menu has
        // rows before the first process ever starts.
        if (next.cachedModels && next.cachedModels.length > 0) {
          store.dispatch({ kind: "cachedModels", models: next.cachedModels });
        }
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

  /**
   * A model picked before any process exists cannot be pushed with `set_model`
   * — there is nothing to push it to — so it is held here and passed as the
   * `model` parameter of the first start.
   */
  const pendingModel = useRef<{ model: string; effort?: EffortLevel } | undefined>(undefined);

  /**
   * Which session this pane is actually on. Tracked from the live init frame,
   * with the restore snapshot only as the pre-first-start fallback: resuming
   * `context.restore.sessionId` after the pane has moved on reopens whatever
   * the panel was serialized with, not the conversation on screen.
   */
  const currentSessionId = useCallback(
    (): string | undefined => store.getSnapshot().session.sessionId ?? context?.restore?.sessionId,
    [context, store]
  );

  const startOptions = useCallback(
    (params: StartParams): StartParams => ({
      ...params,
      model: params.model ?? pendingModel.current?.model ?? context?.restore?.model,
      effort: params.effort ?? pendingModel.current?.effort,
      permissionMode: params.permissionMode ?? context?.restore?.permissionMode
    }),
    [context]
  );

  const ensureStarted = useCallback(
    async (resumeSessionId?: string, fork?: boolean) => {
      if (started.current && !resumeSessionId) return;
      started.current = true;
      await bridge
        .start(startOptions({ resumeSessionId: resumeSessionId ?? currentSessionId(), forkSession: fork }))
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
    [bridge, currentSessionId, startOptions, store]
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
      // The CLI drops the queue when asked to; the chips have to go with it, or
      // the pane keeps queueing behind messages that will never be sent.
      if (cancelQueued) store.dispatch({ kind: "clearQueued" });
      bridge.interrupt({ cancelQueued }).catch(() => undefined);
    },
    [bridge, store]
  );

  const cancelQueued = useCallback(
    (uuid: string) => {
      store.dispatch({ kind: "cancelQueued", uuid });
      bridge.cancelQueued({ messageUuid: uuid }).catch(() => undefined);
    },
    [bridge, store]
  );

  /**
   * The one path that swaps which session the pane is running. `bridge.restart`
   * tears the live process down and awaits it before starting again — calling
   * `start` while a process is up is what produced "A Claude session is already
   * running" on every session pick and every New Session.
   */
  const runRestart = useCallback(
    async (params: StartParams): Promise<void> => {
      setRestarting(true);
      started.current = true;
      try {
        const { runId } = await bridge.restart(startOptions(params));
        // The native side emits its own runStarted; replaying it here is
        // idempotent and is what clears a startFailed left by the attempt the
        // user is retrying, without waiting on event delivery to repaint.
        store.receive([{ kind: "runStarted", runId }]);
        store.flushNow();
      } catch (error: unknown) {
        started.current = false;
        store.dispatch({
          kind: "startFailed",
          error: error instanceof Error ? error.message : undefined
        });
        throw error;
      } finally {
        setRestarting(false);
      }
    },
    [bridge, startOptions, store]
  );

  const restart = useCallback(
    (resumeSessionId?: string, fork?: boolean) => {
      const target = resumeSessionId ?? currentSessionId();
      const load = target
        ? bridge
            .loadSessionHistory({ sessionId: target })
            .then((result) => {
              store.dispatch({ kind: "reset" });
              store.receive(result.events.map((line) => ({ kind: "protocol" as const, line })));
            })
            .catch(() => undefined)
        : Promise.resolve();
      void load.then(() =>
        runRestart({ resumeSessionId: target, forkSession: fork }).catch(() => undefined)
      );
    },
    [bridge, currentSessionId, runRestart, store]
  );

  /** Explicitly NOT a resume: no session id goes down, and the pane is cleared. */
  const newSession = useCallback(() => {
    store.dispatch({ kind: "reset" });
    restoredSessionId.current = undefined;
    void runRestart({}).catch(() => undefined);
  }, [runRestart, store]);

  const openSessionInNewPane = useCallback(
    (sessionId: string) => {
      bridge.openSessionInNewPane({ sessionId }).catch(() => undefined);
    },
    [bridge]
  );

  const rewindPreview = useCallback(
    (uuid: string) => bridge.rewindPreview({ userMessageUuid: uuid }),
    [bridge]
  );

  const rewind = useCallback(
    async (request: RewindRequest, restoreFiles: boolean) => {
      setRestarting(true);
      started.current = true;
      try {
        await bridge.rewind({
          userMessageUuid: request.uuid,
          restoreFiles,
          resumeAtUuid: request.resumeAtUuid
        });
        // Only after the native side confirms: a failed rewind that had already
        // deleted the turns locally would leave the pane showing less
        // conversation than the session still has.
        store.dispatch({ kind: "truncateBeforeUserMessage", uuid: request.uuid });
        setDraftState(request.text);
        bridge.saveDraft({ text: request.text }).catch(() => undefined);
      } finally {
        setRestarting(false);
      }
    },
    [bridge, store]
  );

  const setModel = useCallback(
    (next: string, effort?: EffortLevel) => {
      store.dispatch({ kind: "setModel", model: next, effort });
      if (!started.current) {
        // Nothing to tell yet — it rides along on the first start instead.
        pendingModel.current = { model: next, effort };
        return;
      }
      pendingModel.current = { model: next, effort };
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
    restarting,
    setDraft,
    send,
    interrupt,
    cancelQueued,
    restart,
    newSession,
    openSessionInNewPane,
    rewindPreview,
    rewind,
    setModel,
    setPermissionMode,
    cyclePermissionMode,
    refreshSessions,
    refreshContext,
    reloadContext
  };
}

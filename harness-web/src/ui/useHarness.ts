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
  /**
   * A spawn is in flight. NOT "this pane has ever started": that question is
   * answered by `model.runPhase`, which the native side keeps honest through
   * runStarted/runExited. This ref exists only so two concurrent sends cannot
   * each spawn a process before either one's phase change lands.
   */
  const starting = useRef(false);
  const bridge = useMemo(() => getBridge(), []);

  useEffect(() => {
    installReceiver({
      onBatch: (events) => store.receive(events),
      onTheme: (next) => setTheme(next)
    });
  }, [store]);

  const restoredSessionId = useRef<string | undefined>(undefined);
  /**
   * The restore snapshot describes the pane as it was SERIALIZED, and it is
   * reread on every `harness.context` call — the binary dialog closing is one.
   * Once the user has deliberately moved this pane (New Session, resuming
   * another session, a rewind), that snapshot is history: replaying it would
   * shove the discarded conversation back on screen over the one the user just
   * chose. So a deliberate swap retires the snapshot permanently.
   */
  const snapshotRetired = useRef(false);

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
        if (sessionId && !snapshotRetired.current && restoredSessionId.current !== sessionId) {
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
    (): string | undefined =>
      store.getSnapshot().session.sessionId ??
      // Only until the pane is deliberately moved: after a New Session the
      // snapshot names the conversation the user just walked away from, and
      // falling back to it turns the next send into a resume of it.
      (snapshotRetired.current ? undefined : context?.restore?.sessionId),
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
      // Whether a process exists is the RUN PHASE's answer, not a latch private
      // to this hook. That latch was wrong in BOTH directions:
      //  - it never cleared on exit, so a pane whose process had died kept
      //    accepting messages and forwarding them to nothing at all; and
      //  - it started false on a pane the native side had already started (a
      //    restored pane, or any run this hook did not itself initiate), so the
      //    first send called `start` against a live process and was refused with
      //    "A Claude session is already running in this pane" — the very error
      //    this round exists to remove, arriving from the other direction.
      // So the phase decides whether a process is there, and `starting` is kept
      // only as the in-flight guard against a duplicate spawn.
      if (resumeSessionId === undefined) {
        const phase = store.getSnapshot().runPhase;
        if (phase === "running" || phase === "starting") return;
        if (starting.current) return;
      }
      starting.current = true;
      await bridge
        .start(startOptions({ resumeSessionId: resumeSessionId ?? currentSessionId(), forkSession: fork }))
        .then(({ runId }) => {
          // The native side emits its own runStarted; applying it here is
          // idempotent and moves the pane out of `exited` immediately, so the
          // sends already queued behind this one on the chain do not each read
          // a stale exited phase and spawn a process of their own.
          store.receive([{ kind: "runStarted", runId }]);
          store.flushNow();
        })
        .catch((error: unknown) => {
          // A silent failure here leaves the composer accepting messages that go
          // nowhere; the exited state carries a Restart button.
          store.dispatch({
            kind: "startFailed",
            error: error instanceof Error ? error.message : undefined
          });
        })
        // Whether it started or failed, this attempt is over: the guard exists
        // only to stop two spawns racing, so leaving it set on the success path
        // would freeze the pane's idea of "a start is in flight" forever.
        .finally(() => {
          starting.current = false;
        });
    },
    [bridge, currentSessionId, startOptions, store]
  );

  /**
   * The tail of the send chain. Ordering the on-screen queue is only half the
   * problem: what the CLI answers is the order `bridge.send` is CALLED in, and
   * that used to be a race. The FIRST send of a pane awaits the process spawn,
   * while every later one has nothing to await — so a message typed second
   * reached the CLI first and was answered first, under a transcript that still
   * listed them the other way round. That is the "a later message jumped ahead
   * of the queued chips" report, and no reducer change can fix it, because the
   * reducer never sees the wire. Every send now appends to one promise, so the
   * calls leave in the order they were typed no matter what any of them waits
   * on. Each link swallows its own rejection: a single failed send must not
   * break the chain and strand every message behind it.
   */
  const sendChain = useRef<Promise<void>>(Promise.resolve());

  /** One link of the send chain: start if needed, then put this message on the wire. */
  const enqueueSend = useCallback(
    (text: string, images: ImageAttachment[] | undefined, uuid: string) => {
      sendChain.current = sendChain.current
        .then(() => ensureStarted())
        .then(() =>
          bridge
            .send({ text, images: images && images.length > 0 ? images : undefined, uuid })
            .then(() => undefined)
        )
        .catch(() => undefined);
    },
    [bridge, ensureStarted]
  );

  const send = useCallback(
    (text: string, images: ImageAttachment[]) => {
      const uuid = uuidv4();
      store.dispatch({ kind: "localSend", uuid, text, images, atMs: Date.now() });
      setDraftState("");
      bridge.saveDraft({ text: "" }).catch(() => undefined);
      enqueueSend(text, images, uuid);
    },
    [bridge, enqueueSend, store]
  );

  /**
   * Messages that were queued inside a run which died before answering them.
   * The CLI-side queue died with the process, so re-sending is the only way they
   * are ever answered — and it happens through the same chain, in the order they
   * were typed, so they cannot overtake each other or anything typed since.
   */
  useEffect(() => {
    if (model.stranded.length === 0) return;
    if (model.runPhase !== "running") return;
    const carried = model.stranded;
    store.dispatch({ kind: "takeStranded" });
    for (const message of carried) {
      store.dispatch({
        kind: "localSend",
        uuid: message.uuid,
        text: message.text,
        images: message.images,
        atMs: message.queuedAtMs
      });
      enqueueSend(message.text, message.images, message.uuid);
    }
  }, [enqueueSend, model.runPhase, model.stranded, store]);

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
      // A restart IS a start in flight: without this, a send racing the restart
      // would see a phase that is not yet `running` and spawn a second process.
      starting.current = true;
      try {
        const { runId } = await bridge.restart(startOptions(params));
        // The native side emits its own runStarted; replaying it here is
        // idempotent and is what clears a startFailed left by the attempt the
        // user is retrying, without waiting on event delivery to repaint.
        store.receive([{ kind: "runStarted", runId }]);
        store.flushNow();
      } catch (error: unknown) {
        store.dispatch({
          kind: "startFailed",
          error: error instanceof Error ? error.message : undefined
        });
        throw error;
      } finally {
        starting.current = false;
        setRestarting(false);
      }
    },
    [bridge, startOptions, store]
  );

  const restart = useCallback(
    (resumeSessionId?: string, fork?: boolean) => {
      const target = resumeSessionId ?? currentSessionId();
      // Picking a session from the browser is a deliberate move off whatever the
      // panel was serialized with; the snapshot must not be replayed over it.
      if (resumeSessionId) {
        snapshotRetired.current = true;
        restoredSessionId.current = resumeSessionId;
      }
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
    // A reset KEEPS unanswered messages, because a Restart after a crash must
    // not eat what the user typed. "New session" is the opposite intent — an
    // empty pane — so it is the one path that discards them explicitly.
    store.dispatch({ kind: "clearQueued" });
    restoredSessionId.current = undefined;
    // The strongest possible statement that this pane is no longer on the
    // snapshot's session: without it the next `harness.context` — the binary
    // dialog closing is one — replays that conversation back into the pane the
    // user just cleared.
    snapshotRetired.current = true;
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
      // A rewind restarts the process, so it is a start in flight for the same
      // reason a restart is.
      starting.current = true;
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
        starting.current = false;
        setRestarting(false);
      }
    },
    [bridge, store]
  );

  const setModel = useCallback(
    (next: string, effort?: EffortLevel) => {
      store.dispatch({ kind: "setModel", model: next, effort });
      // Held either way, because it is also what a later restart re-sends.
      pendingModel.current = { model: next, effort };
      // `set_model` needs a live process to receive it. Pushing it at a pane
      // that has none is not merely useless — the rejection surfaces as a
      // failure for a choice the menu already shows as taken.
      if (store.getSnapshot().runPhase !== "running") return;
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

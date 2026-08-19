import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { getBridge, installReceiver, type HarnessBridge, type StartParams } from "../bridge";
import { resolveModel } from "../model/helpers";
import { HarnessStore } from "../model/store";
import type { ImageAttachment, RelayTarget, TranscriptModel } from "../model/types";
import type {
  EffortLevel,
  HarnessContext,
  HarnessTheme,
  PermissionMode,
  RewindPreview,
  RewindResult,
  SessionSummary
} from "../protocol/types";
import { defaultDarkTheme } from "./theme";

const MODE_CYCLE: PermissionMode[] = ["default", "acceptEdits", "plan", "bypassPermissions"];

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
  /**
   * A message for an AGENT, carried to it through main.
   *
   * Two texts, deliberately: `instruction` is what goes on the wire (the probed
   * "relay this verbatim … reply only RELAYED" pattern), and `text` is what the
   * user actually typed, which is what the chip and the agent's thread show.
   * Collapsing them would either put protocol scaffolding in the user's mouth
   * or send main a bare message it would answer itself.
   */
  sendRelay(
    instruction: string,
    text: string,
    target: RelayTarget,
    backgrounded: boolean | undefined
  ): void;
  interrupt(cancelQueued: boolean): void;
  cancelQueued(uuid: string): void;
  restart(resumeSessionId?: string, fork?: boolean): void;
  newSession(): void;
  openSessionInNewPane(sessionId: string): void;
  rewindPreview(uuid: string): Promise<RewindPreview>;
  /**
   * Resolves once the conversation has been rewound. The file half reports
   * separately in the result, because it can fail on its own without
   * invalidating the rewind.
   */
  rewind(request: RewindRequest, restoreFiles: boolean): Promise<RewindResult>;
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
  /** Whether the pane's initial native permission snapshot has been projected into the store. */
  const permissionModeBootstrapComplete = useRef(false);
  /**
   * Whether the restore snapshot's MODEL has been projected into the store.
   *
   * This is the round-5 "trigger says Model" bug: the last fix made `newSession`
   * capture `session.model` before reset, but on a restored pane that had not
   * started a process NOTHING had ever written `session.model` — the restored
   * model lived only in `context.restore.model`, which `startOptions` read as a
   * wire fallback while the trigger read the empty store. So the pill showed the
   * bare placeholder, and New Session carried nothing. The snapshot's model is
   * projected into the store once, exactly like the permission mode above, and
   * from then on the store is the single authority every surface already reads.
   */
  const modelBootstrapComplete = useRef(false);
  /**
   * Set only by the shared user mutation path. This is intent, not a second copy
   * of the mode: the authoritative value remains `session.permissionMode`.
   */
  const permissionModeWasSelected = useRef(false);
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
        if (!permissionModeBootstrapComplete.current) {
          const restoredMode = next.restore?.permissionMode;
          if (restoredMode && !permissionModeWasSelected.current) {
            store.dispatch({ kind: "setPermissionMode", mode: restoredMode });
          }
          permissionModeBootstrapComplete.current = true;
        }
        if (!modelBootstrapComplete.current) {
          const restoredModel = next.restore?.model;
          // Only while the store has no answer of its own: an init frame or a
          // picker choice that already landed outranks the serialized snapshot.
          if (restoredModel && !store.getSnapshot().session.model) {
            store.dispatch({ kind: "setModel", model: restoredModel });
          }
          modelBootstrapComplete.current = true;
        }
        const sessionId = next.restore?.sessionId;
        if (sessionId && !snapshotRetired.current && restoredSessionId.current !== sessionId) {
          restoredSessionId.current = sessionId;
          bridge
            .loadSessionHistory({ sessionId })
            .then((result) => {
              const selectedMode = permissionModeWasSelected.current
                ? store.getSnapshot().session.permissionMode
                : undefined;
              store.dispatch({ kind: "reset" });
              if (result.truncated) store.dispatch({ kind: "historyTruncated" });
              store.receive(result.events.map((line) => ({ kind: "protocol" as const, line })));
              store.flushNow();
              // Settle the replayed turns (no `result` frames exist on disk)
              // and adopt the replayed session's own model for the trigger.
              store.dispatch({ kind: "historyReplayed" });
              if (selectedMode) {
                store.dispatch({ kind: "setPermissionMode", mode: selectedMode });
              }
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
    (params: StartParams): StartParams => {
      const snapshot = store.getSnapshot();
      const session = snapshot.session;
      // The store is the authoritative selection whether it came from an init
      // frame, the model picker, or a resumed session's own history. Sent as
      // the catalog SELECTOR when one resolves — `session.model` often holds a
      // resolved id ("claude-opus-5") straight off the wire, and the selector
      // ("opus") is the form every model input takes.
      const selected = session.model
        ? resolveModel(session, snapshot.cachedModels)?.value ?? session.model
        : undefined;
      return {
        ...params,
        model: params.model ?? selected ?? context?.restore?.model,
        effort: params.effort ?? session.effort,
        permissionMode:
          params.permissionMode ??
          session.permissionMode ??
          context?.restore?.permissionMode ??
          "bypassPermissions"
      };
    },
    [context, store]
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

  /**
   * Put the messages a dead run never answered back on the wire, in the order
   * they were typed. `model.stranded` is the record the reducer captured AT THE
   * EXIT BOUNDARY, so everything in it was typed before anything that arrives
   * afterwards — draining it through the same chain is what keeps that true on
   * the wire as well as on screen.
   *
   * One function, two callers, because a crash has exactly two ways out and they
   * must not disagree about order: a run comes back up (the effect below), or
   * the user types the next message first (`send`, which drains this ahead of
   * its own message rather than jumping the line).
   */
  const flushStranded = useCallback((): boolean => {
    const carried = store.getSnapshot().stranded;
    if (carried.length === 0) return false;
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
    return true;
  }, [enqueueSend, store]);

  const send = useCallback(
    (text: string, images: ImageAttachment[]) => {
      // BEFORE this message, always. A send typed after a crash used to reach
      // `bridge.send` first and be answered first: it had a live chain to append
      // to, while the stranded messages were still waiting for a `runStarted`
      // that this very send was about to trigger. The chips said one order and
      // the CLI answered another.
      flushStranded();
      const uuid = uuidv4();
      store.dispatch({ kind: "localSend", uuid, text, images, atMs: Date.now() });
      setDraftState("");
      bridge.saveDraft({ text: "" }).catch(() => undefined);
      enqueueSend(text, images, uuid);
    },
    [bridge, enqueueSend, flushStranded, store]
  );

  const sendRelay = useCallback(
    (instruction: string, text: string, target: RelayTarget, backgrounded: boolean | undefined) => {
      flushStranded();
      const uuid = uuidv4();
      // The model records the user's OWN text against this uuid; the wire gets
      // the instruction. One uuid ties the two together, which is what lets the
      // main transcript draw a chip where the instruction's bubble would be.
      store.dispatch({
        kind: "localSend",
        uuid,
        text,
        atMs: Date.now(),
        relay: target,
        backgrounded
      });
      setDraftState("");
      bridge.saveDraft({ text: "" }).catch(() => undefined);
      enqueueSend(instruction, undefined, uuid);
    },
    [bridge, enqueueSend, flushStranded, store]
  );

  /**
   * The other way out of a crash: a run came back up — a Restart, or a resume —
   * with nobody having typed since. The CLI-side queue died with the process, so
   * re-sending is the only way these are ever answered.
   */
  useEffect(() => {
    if (model.stranded.length === 0) return;
    if (model.runPhase !== "running") return;
    flushStranded();
  }, [flushStranded, model.runPhase, model.stranded]);

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
              if (result.truncated) store.dispatch({ kind: "historyTruncated" });
              store.receive(result.events.map((line) => ({ kind: "protocol" as const, line })));
              // Drain the replay before building restart params so a selection
              // from the old session cannot be sent back over the session being
              // resumed. History carries NO init frame — the disk mapper only
              // forwards user/assistant records — so `historyReplayed` is what
              // settles the replayed turns and adopts the resumed session's own
              // last-used model (its last assistant frame) for the trigger and
              // the restart params.
              store.flushNow();
              store.dispatch({ kind: "historyReplayed" });
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
    // Capture before reset. This is the selection actually in effect, whether it
    // came from the model picker or from the CLI's init frame.
    const current = store.getSnapshot().session;
    const carried = current.model
      ? { model: current.model, effort: current.effort }
      : {};
    // resetConversation preserves session preferences, so this synchronous
    // dispatch clears the transcript without ever exposing an empty model pill.
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
    void runRestart(carried).catch(() => undefined);
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
    async (request: RewindRequest, restoreFiles: boolean): Promise<RewindResult> => {
      setRestarting(true);
      // A rewind restarts the process, so it is a start in flight for the same
      // reason a restart is.
      starting.current = true;
      try {
        const result = await bridge.rewind({
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
        // A file restore that failed does NOT invalidate the conversation
        // rewind, so it comes back in the result rather than as a rejection —
        // the caller decides what to say about the half that did not happen.
        return result;
      } finally {
        starting.current = false;
        setRestarting(false);
      }
    },
    [bridge, store]
  );

  const setModel = useCallback(
    (next: string, effort?: EffortLevel) => {
      // One authoritative copy. startOptions reads this same session state when a
      // process does not exist yet or a later restart needs to resend the choice.
      store.dispatch({ kind: "setModel", model: next, effort });
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
      permissionModeWasSelected.current = true;
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
    sendRelay,
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

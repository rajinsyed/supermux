import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useSyncExternalStore
} from "react";
import { getBridge } from "../bridge";
import { applyLine, createIndex, createModel, type TranscriptIndex } from "../model/transcript";
import type { TranscriptModel } from "../model/types";
import type { ProtocolLine, SubagentTranscript } from "../protocol/types";

export interface SubagentTranscriptTarget {
  taskId?: string;
  workflowRunId?: string;
  agentId?: string;
}

export type SubagentTranscriptPhase = "loading" | "ready" | "missing" | "failed";

export interface SubagentTranscriptResourceSnapshot {
  identity: string;
  phase: SubagentTranscriptPhase;
  model?: TranscriptModel;
  events: readonly ProtocolLine[];
  sourceGeneration: number;
  truncated: boolean;
  meta?: { agentType?: string; description?: string; spawnDepth?: number };
}

type RefreshSignal =
  | { kind: "progress"; tick: number }
  | { kind: "terminal" }
  | { kind: "manual"; nonce: number };

interface PendingRefresh {
  key: string;
}

function identityOf(target: SubagentTranscriptTarget): string {
  if (target.taskId) return `local:${target.taskId}`;
  if (target.workflowRunId && target.agentId) {
    return `workflow:${target.workflowRunId}:${target.agentId}`;
  }
  return "invalid";
}

function validTarget(target: SubagentTranscriptTarget): boolean {
  return (target.taskId?.length ?? 0) > 0
    || ((target.workflowRunId?.length ?? 0) > 0 && (target.agentId?.length ?? 0) > 0);
}

class SubagentTranscriptEntry {
  readonly identity: string;
  private readonly target: SubagentTranscriptTarget;
  private snapshot: SubagentTranscriptResourceSnapshot;
  private listeners = new Set<() => void>();
  private retainedEvents: ProtocolLine[] = [];
  private model = createModel();
  private index: TranscriptIndex = createIndex();
  private revision: number | undefined;
  private active: PendingRefresh | undefined;
  private pending: PendingRefresh | undefined;
  private lastSettledSignalKey: string | undefined;
  private latestProgressTick: number | undefined;
  private retainCount = 0;

  constructor(target: SubagentTranscriptTarget) {
    this.target = { ...target };
    this.identity = identityOf(target);
    this.snapshot = {
      identity: this.identity,
      phase: "loading",
      events: this.retainedEvents,
      sourceGeneration: 0,
      truncated: false
    };
  }

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getSnapshot = (): SubagentTranscriptResourceSnapshot => this.snapshot;

  retain(): void {
    this.retainCount += 1;
  }

  release(): void {
    this.retainCount = Math.max(0, this.retainCount - 1);
  }

  request(signal: RefreshSignal): void {
    const refresh = this.normalize(signal);
    if (this.active?.key === refresh.key || this.pending?.key === refresh.key) return;
    if (this.active) {
      // A second consumer repeating the active signal must not erase a newer
      // queued signal. Every genuinely newer signal replaces the old pending
      // one, which is the latest-wins progress policy.
      this.pending = refresh;
      return;
    }
    if (this.lastSettledSignalKey === refresh.key) return;
    this.start(refresh);
  }

  private normalize(signal: RefreshSignal): PendingRefresh {
    if (signal.kind === "progress") {
      this.latestProgressTick = signal.tick;
      return { key: `progress:${signal.tick}` };
    }
    if (signal.kind === "terminal") {
      return { key: `terminal:${this.latestProgressTick ?? "initial"}` };
    }
    return { key: `manual:${signal.nonce}` };
  }

  private start(refresh: PendingRefresh): void {
    this.active = refresh;
    if (!validTarget(this.target)) {
      this.applyMissing();
      this.finish(refresh.key);
      return;
    }
    const afterRevision = this.revision;
    getBridge()
      .loadSubagentTranscript({
        taskId: this.target.taskId,
        workflowRunId: this.target.workflowRunId,
        agentId: this.target.agentId,
        afterRevision
      })
      .then((result) => {
        if (this.active?.key !== refresh.key) return;
        if (this.retainCount === 0) {
          this.abandon(refresh.key);
          return;
        }
        this.apply(result);
        this.finish(refresh.key);
      })
      .catch(() => {
        if (this.active?.key !== refresh.key) return;
        if (this.retainCount === 0) {
          this.abandon(refresh.key);
          return;
        }
        if (this.snapshot.phase === "loading" || this.snapshot.phase === "failed") {
          this.publish({ ...this.snapshot, phase: "failed" });
        }
        this.finish(refresh.key);
      });
  }

  private finish(signalKey: string): void {
    if (this.active?.key !== signalKey) return;
    this.active = undefined;
    this.lastSettledSignalKey = signalKey;
    const next = this.pending;
    this.pending = undefined;
    if (next && next.key !== this.lastSettledSignalKey) this.start(next);
  }

  private abandon(signalKey: string): void {
    if (this.active?.key !== signalKey) return;
    this.active = undefined;
    this.pending = undefined;
  }

  private apply(result: SubagentTranscript): void {
    const incomingRevision = result.revision;
    if (
      incomingRevision !== undefined
      && this.revision !== undefined
      && incomingRevision < this.revision
    ) {
      return;
    }
    const legacyReplacement = incomingRevision === undefined || result.replace === undefined;
    const replace = legacyReplacement || result.replace === true || result.missing === true;
    const dropped = Math.max(0, result.droppedEventCount ?? 0);
    let transcriptChanged = false;

    if (replace) {
      this.retainedEvents = result.missing ? [] : [...result.events];
      this.rebuild();
      transcriptChanged = true;
    } else if (incomingRevision === this.revision) {
      // An equal revision is an unchanged acknowledgement. Metadata mutations
      // are revisioned natively too, so applying payload at the same revision
      // would allow a replayed response to paint stale state.
    } else if (dropped > 0) {
      this.retainedEvents = [
        ...this.retainedEvents.slice(Math.min(dropped, this.retainedEvents.length)),
        ...result.events
      ];
      this.rebuild();
      transcriptChanged = true;
    } else if (result.events.length > 0) {
      this.retainedEvents = [...this.retainedEvents, ...result.events];
      const now = Date.now();
      for (const line of result.events) {
        this.model = applyLine(this.model, this.index, line, now);
      }
      transcriptChanged = true;
    }

    if (incomingRevision !== undefined) this.revision = incomingRevision;
    let meta = this.snapshot.meta;
    if (Object.prototype.hasOwnProperty.call(result, "meta")) {
      meta = result.meta ?? undefined;
    }
    if (result.missing) {
      this.publish({
        identity: this.identity,
        phase: "missing",
        events: this.retainedEvents,
        sourceGeneration: transcriptChanged
          ? this.snapshot.sourceGeneration + 1
          : this.snapshot.sourceGeneration,
        truncated: false,
        meta
      });
      return;
    }
    this.publish({
      identity: this.identity,
      phase: "ready",
      model: this.model,
      events: this.retainedEvents,
      sourceGeneration: transcriptChanged
        ? this.snapshot.sourceGeneration + 1
        : this.snapshot.sourceGeneration,
      truncated: result.truncated === true,
      meta
    });
  }

  private applyMissing(): void {
    this.retainedEvents = [];
    this.model = createModel();
    this.index = createIndex();
    this.publish({
      identity: this.identity,
      phase: "missing",
      events: this.retainedEvents,
      sourceGeneration: this.snapshot.sourceGeneration,
      truncated: false
    });
  }

  private rebuild(): void {
    this.model = createModel();
    this.index = createIndex();
    const now = Date.now();
    for (const line of this.retainedEvents) {
      this.model = applyLine(this.model, this.index, line, now);
    }
  }

  private publish(snapshot: SubagentTranscriptResourceSnapshot): void {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}

class SubagentTranscriptResourceStore {
  private entries = new Map<string, SubagentTranscriptEntry>();
  private manualNonce = 0;

  entry(target: SubagentTranscriptTarget): SubagentTranscriptEntry {
    const identity = identityOf(target);
    const existing = this.entries.get(identity);
    if (existing) return existing;
    const entry = new SubagentTranscriptEntry(target);
    this.entries.set(identity, entry);
    return entry;
  }

  nextManualNonce(): number {
    this.manualNonce += 1;
    return this.manualNonce;
  }
}

const SubagentTranscriptResourceContext =
  createContext<SubagentTranscriptResourceStore | undefined>(undefined);

export function SubagentTranscriptResourceProvider({
  generation,
  children
}: {
  generation: number;
  children: React.ReactNode;
}) {
  const store = useMemo(() => new SubagentTranscriptResourceStore(), [generation]);
  return (
    <SubagentTranscriptResourceContext.Provider value={store}>
      {children}
    </SubagentTranscriptResourceContext.Provider>
  );
}

export function useSubagentTranscriptResource(
  target: SubagentTranscriptTarget,
  wanted: boolean,
  tick: number | undefined
): SubagentTranscriptResourceSnapshot & { reload(): void } {
  const providedStore = useContext(SubagentTranscriptResourceContext);
  const fallbackStore = useRef<SubagentTranscriptResourceStore | undefined>(undefined);
  if (!fallbackStore.current) fallbackStore.current = new SubagentTranscriptResourceStore();
  const store = providedStore ?? fallbackStore.current;
  const identity = identityOf(target);
  const entry = useMemo(() => store.entry(target), [identity, store]);
  const snapshot = useSyncExternalStore(entry.subscribe, entry.getSnapshot, entry.getSnapshot);

  useEffect(() => {
    if (!wanted) return;
    entry.retain();
    return () => entry.release();
  }, [entry, wanted]);

  useEffect(() => {
    if (!wanted) return;
    entry.request(tick === undefined ? { kind: "terminal" } : { kind: "progress", tick });
  }, [entry, tick, wanted]);

  const reload = useCallback(() => {
    entry.request({ kind: "manual", nonce: store.nextManualNonce() });
  }, [entry, store]);
  return { ...snapshot, reload };
}

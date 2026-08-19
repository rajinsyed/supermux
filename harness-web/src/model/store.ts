import type { NativeEvent } from "../protocol/types";
import { applyEvents, applyLocalAction, createIndex, createModel } from "./transcript";
import type { LocalAction, RelayRecord, TranscriptModel, Turn } from "./types";

type Listener = () => void;
type ScheduledDrain = { kind: "animationFrame" | "timeout"; id: number };

export interface TurnSnapshot {
  turn: Turn;
  relay?: RelayRecord;
}

export class HarnessStore {
  private model: TranscriptModel = createModel();
  private index = createIndex();
  private queue: NativeEvent[] = [];
  private scheduled: ScheduledDrain | undefined;
  private rootListeners = new Set<Listener>();
  private turnListeners = new Map<string, Set<Listener>>();
  private lastTurnRevisions = new Map<string, number>();
  private lastRelaysByTurn = new Map<string, RelayRecord | undefined>();
  private lastTurnIds: string[] = [];
  private turnsById = new Map<string, Turn>();
  private turnSnapshots = new Map<string, TurnSnapshot>();

  getSnapshot = (): TranscriptModel => this.model;

  subscribe = (listener: Listener): (() => void) => {
    this.rootListeners.add(listener);
    return () => {
      this.rootListeners.delete(listener);
    };
  };

  subscribeTurn = (turnId: string, listener: Listener): (() => void) => {
    let set = this.turnListeners.get(turnId);
    if (!set) {
      set = new Set();
      this.turnListeners.set(turnId, set);
    }
    set.add(listener);
    return () => {
      const current = this.turnListeners.get(turnId);
      if (!current) return;
      current.delete(listener);
      if (current.size === 0) this.turnListeners.delete(turnId);
    };
  };

  getTurn = (turnId: string): Turn | undefined => this.turnsById.get(turnId);

  getTurnIds = (): readonly string[] => this.lastTurnIds;

  getTurnSnapshot = (turnId: string): TurnSnapshot | undefined =>
    this.turnSnapshots.get(turnId);

  receive = (events: NativeEvent[]): void => {
    if (events.length === 0) return;
    for (const event of events) this.queue.push(event);
    this.schedule();
  };

  dispatch = (action: LocalAction): void => {
    this.model = applyLocalAction(this.model, this.index, action, Date.now());
    this.notify();
  };

  flushNow = (): void => {
    const scheduled = this.scheduled;
    this.scheduled = undefined;
    if (scheduled?.kind === "animationFrame") {
      globalThis.cancelAnimationFrame?.(scheduled.id);
    } else if (scheduled?.kind === "timeout") {
      globalThis.clearTimeout(scheduled.id);
    }
    this.drain();
  };

  private schedule(): void {
    if (this.scheduled) return;
    if (typeof globalThis.requestAnimationFrame === "function") {
      const id = globalThis.requestAnimationFrame(() => {
        this.scheduled = undefined;
        this.drain();
      });
      this.scheduled = { kind: "animationFrame", id };
      return;
    }
    const id = globalThis.setTimeout(() => {
      this.scheduled = undefined;
      this.drain();
    }, 16) as unknown as number;
    this.scheduled = { kind: "timeout", id };
  }

  private drain(): void {
    if (this.queue.length === 0) return;
    const batch = this.queue;
    this.queue = [];
    this.model = applyEvents(this.model, this.index, batch, Date.now());
    this.notify();
  }

  private notify(): void {
    const ids = this.model.turns.map((turn) => turn.id);
    const structureChanged =
      ids.length !== this.lastTurnIds.length ||
      ids.some((id, index) => id !== this.lastTurnIds[index]);
    const nextTurnsById = new Map<string, Turn>();
    const nextSnapshots = new Map<string, TurnSnapshot>();
    const changedIds: string[] = [];

    for (const turn of this.model.turns) {
      nextTurnsById.set(turn.id, turn);
      const relay = turn.userUuid ? this.model.relays[turn.userUuid] : undefined;
      const revisionChanged = this.lastTurnRevisions.get(turn.id) !== turn.revision;
      const relayChanged = this.lastRelaysByTurn.get(turn.id) !== relay;
      const previousSnapshot = this.turnSnapshots.get(turn.id);
      nextSnapshots.set(
        turn.id,
        !revisionChanged && !relayChanged && previousSnapshot
          ? previousSnapshot
          : { turn, relay }
      );
      this.lastTurnRevisions.set(turn.id, turn.revision);
      this.lastRelaysByTurn.set(turn.id, relay);
      if (revisionChanged || relayChanged) changedIds.push(turn.id);
    }

    // Publish snapshots before listeners run: useSyncExternalStore reads them
    // synchronously from inside the notification.
    this.turnsById = nextTurnsById;
    this.turnSnapshots = nextSnapshots;
    for (const id of changedIds) {
      for (const listener of this.turnListeners.get(id) ?? []) listener();
    }

    if (structureChanged) {
      this.lastTurnIds = ids;
      const live = new Set(ids);
      for (const id of this.lastTurnRevisions.keys()) {
        if (live.has(id)) continue;
        this.lastTurnRevisions.delete(id);
        this.lastRelaysByTurn.delete(id);
      }
    }
    for (const listener of this.rootListeners) listener();
  }
}

export const harnessStore = new HarnessStore();

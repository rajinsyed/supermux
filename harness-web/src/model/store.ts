import type { NativeEvent } from "../protocol/types";
import { applyEvents, applyLocalAction, createIndex, createModel } from "./transcript";
import type { LocalAction, TranscriptModel, Turn } from "./types";

type Listener = () => void;

export class HarnessStore {
  private model: TranscriptModel = createModel();
  private index = createIndex();
  private queue: NativeEvent[] = [];
  private frame = 0;
  private rootListeners = new Set<Listener>();
  private turnListeners = new Map<string, Set<Listener>>();
  private lastTurnRevisions = new Map<string, number>();
  private lastTurnIds: string[] = [];

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

  getTurn = (turnId: string): Turn | undefined =>
    this.model.turns.find((turn) => turn.id === turnId);

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
    if (this.frame) {
      cancelAnimationFrame(this.frame);
      this.frame = 0;
    }
    this.drain();
  };

  private schedule(): void {
    if (this.frame) return;
    const raf =
      typeof requestAnimationFrame === "function"
        ? requestAnimationFrame
        : (cb: FrameRequestCallback) => setTimeout(() => cb(Date.now()), 16) as unknown as number;
    this.frame = raf(() => {
      this.frame = 0;
      this.drain();
    }) as unknown as number;
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
      ids.length !== this.lastTurnIds.length || ids.some((id, i) => id !== this.lastTurnIds[i]);
    for (const turn of this.model.turns) {
      const previous = this.lastTurnRevisions.get(turn.id);
      if (previous === turn.revision) continue;
      this.lastTurnRevisions.set(turn.id, turn.revision);
      const listeners = this.turnListeners.get(turn.id);
      if (!listeners) continue;
      for (const listener of listeners) listener();
    }
    if (structureChanged) {
      this.lastTurnIds = ids;
      const live = new Set(ids);
      for (const id of this.lastTurnRevisions.keys()) {
        if (!live.has(id)) this.lastTurnRevisions.delete(id);
      }
    }
    for (const listener of this.rootListeners) listener();
  }
}

export const harnessStore = new HarnessStore();

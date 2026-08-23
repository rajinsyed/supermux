import type {
  NativeEvent,
  NativeEventAcknowledgement,
  NativeEventEnvelope,
  PresentationVisibilityControl
} from "../protocol/types";
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
  private executionListeners = new Set<Listener>();
  private presentationListeners = new Set<Listener>();
  private turnListeners = new Map<string, Set<Listener>>();
  private presentationVisible = true;
  private documentEpoch: string | undefined;
  private appliedSequence = 0;
  private pendingRevealTarget: number | undefined;
  private deferredRootNotification = false;
  private deferredTurnNotifications = new Set<string>();
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

  /** Non-presentation lifecycle work stays live while React publication is deferred. */
  subscribeExecution = (listener: Listener): (() => void) => {
    this.executionListeners.add(listener);
    return () => {
      this.executionListeners.delete(listener);
    };
  };

  subscribePresentation = (listener: Listener): (() => void) => {
    this.presentationListeners.add(listener);
    return () => {
      this.presentationListeners.delete(listener);
    };
  };

  getPresentationVisible = (): boolean => this.presentationVisible;

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

  /**
   * Reduce one native contract synchronously. Returning means every event through
   * `highestSequence` is already reflected by the reducer and stable snapshots.
   */
  receiveEnvelope = (envelope: NativeEventEnvelope): NativeEventAcknowledgement | undefined => {
    if (!this.isValidEnvelope(envelope)) return undefined;
    if (this.documentEpoch === undefined) {
      this.documentEpoch = envelope.documentEpoch;
    } else if (this.documentEpoch !== envelope.documentEpoch) {
      return undefined;
    }

    if (envelope.highestSequence <= this.appliedSequence) {
      return this.acknowledgement(envelope.documentEpoch, envelope.highestSequence);
    }
    if (envelope.firstSequence !== this.appliedSequence + 1) return undefined;

    for (const event of envelope.events) this.queue.push(event);
    this.flushNow();
    this.appliedSequence = envelope.highestSequence;
    this.completePendingRevealIfReady();
    return this.acknowledgement(envelope.documentEpoch, envelope.highestSequence);
  };

  setPresentationVisibility = (control: PresentationVisibilityControl): boolean => {
    if (
      control.documentEpoch.length === 0 ||
      !Number.isSafeInteger(control.targetSequence) ||
      control.targetSequence < 0
    ) {
      return false;
    }
    if (this.documentEpoch === undefined) {
      this.documentEpoch = control.documentEpoch;
    } else if (this.documentEpoch !== control.documentEpoch) {
      return false;
    }

    if (!control.visible) {
      this.pendingRevealTarget = undefined;
      this.setEffectivePresentationVisibility(false);
      return true;
    }

    if (this.appliedSequence < control.targetSequence) {
      this.pendingRevealTarget = control.targetSequence;
      this.setEffectivePresentationVisibility(false);
      return false;
    }

    this.pendingRevealTarget = undefined;
    this.revealAndPublishDeferredChanges();
    return true;
  };

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

  private isValidEnvelope(envelope: NativeEventEnvelope): boolean {
    if (
      envelope.version !== 1 ||
      envelope.documentEpoch.length === 0 ||
      envelope.events.length === 0 ||
      !Number.isSafeInteger(envelope.firstSequence) ||
      !Number.isSafeInteger(envelope.highestSequence) ||
      envelope.firstSequence < 1 ||
      envelope.highestSequence < envelope.firstSequence
    ) {
      return false;
    }
    return envelope.highestSequence - envelope.firstSequence + 1 === envelope.events.length;
  }

  private acknowledgement(
    documentEpoch: string,
    highestSequence: number
  ): NativeEventAcknowledgement {
    return { version: 1, documentEpoch, highestSequence };
  }

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

    // Publish snapshots before every listener: both execution subscribers and
    // useSyncExternalStore read them synchronously from their notification.
    this.turnsById = nextTurnsById;
    this.turnSnapshots = nextSnapshots;
    if (structureChanged) {
      this.lastTurnIds = ids;
      const live = new Set(ids);
      for (const id of this.lastTurnRevisions.keys()) {
        if (live.has(id)) continue;
        this.lastTurnRevisions.delete(id);
        this.lastRelaysByTurn.delete(id);
      }
    }

    if (this.presentationVisible) {
      for (const id of changedIds) this.notifyTurn(id);
      for (const listener of this.rootListeners) listener();
    } else {
      for (const id of changedIds) this.deferredTurnNotifications.add(id);
      this.deferredRootNotification = true;
    }
    for (const listener of this.executionListeners) listener();
  }

  private notifyTurn(turnId: string): void {
    for (const listener of this.turnListeners.get(turnId) ?? []) listener();
  }

  private setEffectivePresentationVisibility(visible: boolean): void {
    if (this.presentationVisible === visible) return;
    this.presentationVisible = visible;
    for (const listener of this.presentationListeners) listener();
  }

  private completePendingRevealIfReady(): void {
    const target = this.pendingRevealTarget;
    if (target === undefined || this.appliedSequence < target) return;
    this.pendingRevealTarget = undefined;
    this.revealAndPublishDeferredChanges();
  }

  private revealAndPublishDeferredChanges(): void {
    this.setEffectivePresentationVisibility(true);
    for (const id of this.deferredTurnNotifications) this.notifyTurn(id);
    this.deferredTurnNotifications.clear();
    if (!this.deferredRootNotification) return;
    this.deferredRootNotification = false;
    for (const listener of this.rootListeners) listener();
  }
}

export const harnessStore = new HarnessStore();

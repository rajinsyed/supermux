import {
  createContext,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  type ReactNode
} from "react";

type Listener = () => void;
const MAX_BOOLEAN_ENTRIES = 5000;
const MAX_WAS_LIVE_TURNS = 1000;
const MAX_WAS_LIVE_KEYS_PER_TURN = 256;

/**
 * Pane-scoped state that belongs to the reader rather than the transcript model.
 *
 * Virtual rows and completed folds deliberately unmount. Keeping disclosure
 * choices here lets those subtrees release their DOM without forgetting what the
 * reader opened, wrapped, or expanded. The provider is recreated for a new
 * conversation generation, so state can never leak across panes or sessions.
 */
class PresentationStateStore {
  private booleans = new Map<string, boolean>();
  private listeners = new Map<string, Set<Listener>>();
  private wasLiveByTurn = new Map<string, Set<string>>();

  getBoolean(key: string): boolean | undefined {
    return this.booleans.get(key);
  }

  setBoolean(key: string, value: boolean | undefined): void {
    const previous = this.booleans.get(key);
    if (value === undefined) {
      this.booleans.delete(key);
    } else {
      // Insertion order doubles as a bounded LRU for inactive transcript state.
      this.booleans.delete(key);
      this.booleans.set(key, value);
      while (this.booleans.size > MAX_BOOLEAN_ENTRIES) {
        const oldest = this.booleans.keys().next().value;
        if (oldest === undefined) break;
        this.booleans.delete(oldest);
      }
    }
    if (previous === value) return;
    for (const listener of this.listeners.get(key) ?? []) listener();
  }

  subscribe(key: string, listener: Listener): () => void {
    let listeners = this.listeners.get(key);
    if (!listeners) {
      listeners = new Set();
      this.listeners.set(key, listeners);
    }
    listeners.add(listener);
    return () => {
      const current = this.listeners.get(key);
      if (!current) return;
      current.delete(listener);
      if (current.size === 0) this.listeners.delete(key);
    };
  }

  wasLive(turnKey: string): ReadonlySet<string> | undefined {
    return this.wasLiveByTurn.get(turnKey);
  }

  markWasLive(
    turnKey: string,
    blockKeys: readonly string[],
    stoppedBackgroundKeys: readonly string[],
    reachableKeys: readonly string[]
  ): void {
    const reachable = new Set(reachableKeys);
    const previous = this.wasLiveByTurn.get(turnKey);
    const keys = new Set(blockKeys.filter((key) => reachable.has(key)));
    // Stop arrives as two terminal frames (`killed`, then `stopped`). Keep a row
    // that was live through the whole terminal sequence; ordinary sequential
    // tools still disappear because they never enter stoppedBackgroundKeys.
    for (const key of stoppedBackgroundKeys) {
      if (reachable.has(key) && previous?.has(key)) keys.add(key);
    }
    while (keys.size > MAX_WAS_LIVE_KEYS_PER_TURN) {
      const oldest = keys.values().next().value;
      if (oldest === undefined) break;
      keys.delete(oldest);
    }

    this.wasLiveByTurn.delete(turnKey);
    if (keys.size > 0) this.wasLiveByTurn.set(turnKey, keys);
    while (this.wasLiveByTurn.size > MAX_WAS_LIVE_TURNS) {
      const oldest = this.wasLiveByTurn.keys().next().value;
      if (oldest === undefined) break;
      this.wasLiveByTurn.delete(oldest);
    }
  }
}

const PresentationStateContext = createContext<PresentationStateStore | undefined>(undefined);

export function PresentationStateProvider({
  generation,
  children
}: {
  generation: number;
  children: ReactNode;
}) {
  const store = useMemo(() => new PresentationStateStore(), [generation]);
  return (
    <PresentationStateContext.Provider value={store}>
      {children}
    </PresentationStateContext.Provider>
  );
}

/** Supply isolated renders/tests without shadowing an existing pane provider. */
export function PresentationStateBoundary({
  generation = 0,
  children
}: {
  generation?: number;
  children: ReactNode;
}) {
  const existing = useContext(PresentationStateContext);
  if (existing) return children;
  return <PresentationStateProvider generation={generation}>{children}</PresentationStateProvider>;
}

export function usePresentationOverride(
  key: string
): [boolean | undefined, (value: boolean | undefined) => void] {
  const store = useContext(PresentationStateContext);
  const [fallback, setFallback] = useState<boolean | undefined>(undefined);
  const subscribe = useCallback(
    (listener: Listener) => (store ? store.subscribe(key, listener) : () => undefined),
    [key, store]
  );
  const getSnapshot = useCallback(() => store?.getBoolean(key), [key, store]);
  const stored = useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
  const set = useCallback(
    (value: boolean | undefined) => {
      if (store) store.setBoolean(key, value);
      else setFallback(value);
    },
    [key, store]
  );
  return [store ? stored : fallback, set];
}

export function usePresentationState(
  key: string,
  defaultValue = false
): [boolean, (value: boolean | ((previous: boolean) => boolean)) => void] {
  const [override, setOverride] = usePresentationOverride(key);
  const value = override ?? defaultValue;
  const set = useCallback(
    (next: boolean | ((previous: boolean) => boolean)) => {
      setOverride(typeof next === "function" ? next(value) : next);
    },
    [setOverride, value]
  );
  return [value, set];
}

/**
 * Liveness memory for streaming-tail rows. Current live keys are included
 * synchronously; a live background row that enters a stopped state remains
 * retained through every terminal acknowledgement frame.
 */
export function useWasLiveKeys(
  turnKey: string,
  currentLiveKeys: readonly string[],
  stoppedBackgroundKeys: readonly string[],
  reachableKeys: readonly string[]
): ReadonlySet<string> {
  const store = useContext(PresentationStateContext);
  const fallback = useMemo(() => new Set<string>(), [turnKey]);
  useLayoutEffect(() => {
    if (store) {
      store.markWasLive(turnKey, currentLiveKeys, stoppedBackgroundKeys, reachableKeys);
      return;
    }
    const reachable = new Set(reachableKeys);
    const previous = new Set(fallback);
    fallback.clear();
    for (const key of currentLiveKeys) {
      if (reachable.has(key)) fallback.add(key);
    }
    for (const key of stoppedBackgroundKeys) {
      if (reachable.has(key) && previous.has(key)) fallback.add(key);
    }
    while (fallback.size > MAX_WAS_LIVE_KEYS_PER_TURN) {
      const oldest = fallback.values().next().value;
      if (oldest === undefined) break;
      fallback.delete(oldest);
    }
  }, [currentLiveKeys, fallback, reachableKeys, stoppedBackgroundKeys, store, turnKey]);

  return useMemo(() => {
    const keys = new Set(store?.wasLive(turnKey) ?? fallback);
    // Current liveness is canonical turn state, not presentation side state; all
    // active rows remain visible even when the remembered historical set is full.
    for (const key of currentLiveKeys) keys.add(key);
    return keys;
  }, [currentLiveKeys, fallback, store, turnKey]);
}

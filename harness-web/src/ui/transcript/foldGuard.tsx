import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ReactNode
} from "react";

/**
 * The reader's claim on a turn's work tree.
 *
 * A completed turn folds itself away — and a turn that launched background work
 * folds when that work settles, which can be a minute later. Both are right for
 * a transcript nobody is touching and wrong for one somebody is reading: the
 * workflow scenario put an open log strip and an open agent drill-in behind
 * "6 earlier tool calls" six seconds after the run finished, and the reader's
 * place went with them.
 *
 * So a card that is holding something open SAYS so, and the turn declines the
 * automatic fold while any such claim stands. The claim is a render-time fact
 * (an open disclosure), not an event, so it survives re-renders and needs no
 * bookkeeping at the call sites beyond one hook call.
 */
interface FoldGuardHost {
  hold(id: string, held: boolean): void;
}

const FoldGuard = createContext<FoldGuardHost | undefined>(undefined);

/**
 * Declare that this component is showing something the reader opened, so the
 * turn around it must not fold itself away. Safe outside a turn (drill-ins mount
 * inside other drill-ins, and the tasks strip has no turn at all) — the context
 * is simply absent and the hook does nothing.
 */
export function useFoldHold(held: boolean): void {
  const id = useId();
  const host = useContext(FoldGuard);
  useEffect(() => {
    if (!host) return;
    host.hold(id, held);
    return () => host.hold(id, false);
  }, [held, host, id]);
}

/**
 * The turn side of the contract: a provider plus the boolean it derives.
 *
 * Ref-counted by id rather than a plain counter so a card that re-renders while
 * held cannot double-count itself, and an unmount while held (the turn's own
 * fold unmounting a drill-in) always releases.
 */
export function useFoldGuardHost(): { held: boolean; Provider: (props: { children: ReactNode }) => ReactNode } {
  const ids = useRef<Set<string>>(new Set());
  const [held, setHeld] = useState(false);

  const host = useMemo<FoldGuardHost>(
    () => ({
      hold(id: string, on: boolean) {
        if (on) ids.current.add(id);
        else ids.current.delete(id);
        setHeld(ids.current.size > 0);
      }
    }),
    []
  );

  const Provider = useCallback(
    ({ children }: { children: ReactNode }) => (
      <FoldGuard.Provider value={host}>{children}</FoldGuard.Provider>
    ),
    [host]
  );

  return { held, Provider };
}

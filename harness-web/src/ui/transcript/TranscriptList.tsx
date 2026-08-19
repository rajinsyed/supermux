import {
  memo,
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
  type ReactNode,
  type RefObject
} from "react";
import type { HarnessStore } from "../../model/store";
import type { RelayRecord, Turn } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { ArrowDown } from "../Icons";
import { PresentationStateBoundary } from "../presentationState";
import { TurnView } from "./TurnView";
import { useTranscriptWindow } from "./useTranscriptWindow";

interface TranscriptListProps {
  /** Direct snapshots for isolated renders/tests. Production uses turnIds+store. */
  turns?: Turn[];
  /** Stable structure snapshot; unchanged rows subscribe to the store themselves. */
  turnIds?: readonly string[];
  store?: HarnessStore;
  /** Relays for direct snapshot mode. Store mode reads them at the row boundary. */
  relays?: Record<string, RelayRecord>;
  scrollRef: RefObject<HTMLDivElement | null>;
  /** Observed for size changes so late-growing cards keep the bottom pinned. */
  contentRef?: RefObject<HTMLDivElement | null>;
  /** The scroll-follow intent ref shared with the virtual window. */
  following?: RefObject<boolean>;
  /** Atomically updates scroll-follow readings after a measured anchor move. */
  onAnchorCorrection?: (delta: number) => void;
  /** Presentation identity supplied by the conversation owner. */
  resetKey?: number;
  /** User message whose unknown predecessor lies outside truncated history. */
  blockedRewindUuid?: string;
  showPill: boolean;
  onJump: () => void;
  onRewind?: (uuid: string) => void;
  header?: ReactNode;
  footer?: ReactNode;
}

function MeasuredTurn({
  id,
  position,
  total,
  onMeasure,
  children
}: {
  id: string;
  position: number;
  total: number;
  onMeasure(id: string, height: number): void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    const measure = () => onMeasure(id, node.getBoundingClientRect().height || node.offsetHeight);
    measure();
    const observer =
      typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : undefined;
    observer?.observe(node);
    return () => observer?.disconnect();
  }, [id, onMeasure]);
  return (
    <div
      ref={ref}
      className={`virtual-turn${position === total ? " is-last" : ""}`}
      data-virtual-turn-id={id}
    >
      {children}
    </div>
  );
}

const TurnSlot = memo(function TurnSlot({
  id,
  fallback,
  store,
  relay,
  position,
  total,
  generation,
  isLast,
  rewindBlocked,
  onRewind
}: {
  id: string;
  fallback?: Turn;
  store?: HarnessStore;
  relay?: RelayRecord;
  position: number;
  total: number;
  generation: number;
  isLast: boolean;
  rewindBlocked: boolean;
  onRewind?: (uuid: string) => void;
}) {
  const subscribe = useCallback(
    (listener: () => void) => (store ? store.subscribeTurn(id, listener) : () => undefined),
    [id, store]
  );
  const getSnapshot = useCallback(() => store?.getTurnSnapshot(id), [id, store]);
  const snapshot = useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
  const turn = snapshot?.turn ?? fallback;
  const currentRelay = snapshot?.relay ?? relay;
  const onFoldChange = useCallback(
    (folded: boolean) => {
      store?.dispatch({ kind: "toggleFold", turnId: id, folded });
    },
    [id, store]
  );
  if (!turn) return null;
  return (
    <TurnView
      turn={turn}
      isLast={isLast}
      position={position}
      total={total}
      generation={generation}
      onRewind={rewindBlocked ? undefined : onRewind}
      onFoldChange={store ? onFoldChange : undefined}
      relay={currentRelay}
    />
  );
});

export function TranscriptList(props: TranscriptListProps) {
  return (
    <PresentationStateBoundary generation={props.resetKey ?? 0}>
      <TranscriptListBody {...props} />
    </PresentationStateBoundary>
  );
}

function TranscriptListBody({
  turns,
  turnIds,
  store,
  relays,
  scrollRef,
  contentRef,
  following,
  onAnchorCorrection,
  resetKey = 0,
  blockedRewindUuid,
  showPill,
  onJump,
  onRewind,
  header,
  footer
}: TranscriptListProps) {
  const copy = useCopy();
  const ids = useMemo<readonly string[]>(
    () => turnIds ?? turns?.map((turn) => turn.id) ?? [],
    [turnIds, turns]
  );
  const fallbackById = useMemo(
    () => new Map((turns ?? []).map((turn) => [turn.id, turn] as const)),
    [turns]
  );
  const virtual = useTranscriptWindow({
    turnIds: ids,
    scrollRef,
    following,
    resetKey,
    onAnchorCorrection
  });
  const shown = ids.slice(virtual.range.start, virtual.range.end);
  const hiddenBefore = virtual.range.start;
  const hiddenAfter = ids.length - virtual.range.end;

  const jump = useCallback(() => {
    virtual.showLatest();
    requestAnimationFrame(onJump);
  }, [onJump, virtual]);

  return (
    <div className="transcript-wrap">
      <div
        className="harness-scroll transcript"
        ref={scrollRef}
        tabIndex={-1}
        role="log"
        aria-label={copy("supermux.harness.a11y.transcript")}
      >
        <div className="transcript-inner" ref={contentRef}>
          {header}
          <div
            className="transcript-spacer is-top"
            style={{ height: virtual.topHeight }}
            aria-hidden={hiddenBefore > 0 ? undefined : true}
          >
            {hiddenBefore > 0 ? (
              <div className="transcript-earlier">
                <button type="button" className="link-btn" onClick={virtual.showEarlier}>
                  {plural(
                    copy,
                    hiddenBefore,
                    "supermux.harness.turn.earlierMessagesOne",
                    "supermux.harness.turn.earlierMessages"
                  )}
                </button>
              </div>
            ) : null}
          </div>
          {shown.map((id, index) => {
            const fallback = fallbackById.get(id);
            return (
              <MeasuredTurn
                key={id}
                id={id}
                position={virtual.range.start + index + 1}
                total={ids.length}
                onMeasure={virtual.measure}
              >
                <TurnSlot
                  id={id}
                  fallback={fallback}
                  store={store}
                  relay={fallback?.userUuid ? relays?.[fallback.userUuid] : undefined}
                  position={virtual.range.start + index + 1}
                  total={ids.length}
                  generation={resetKey}
                  isLast={virtual.range.start + index === ids.length - 1}
                  rewindBlocked={
                    (fallback?.userUuid ?? store?.getTurnSnapshot(id)?.turn.userUuid) ===
                    blockedRewindUuid
                  }
                  onRewind={onRewind}
                />
              </MeasuredTurn>
            );
          })}
          <div
            className="transcript-spacer is-bottom"
            style={{ height: virtual.bottomHeight }}
            aria-hidden={hiddenAfter > 0 ? undefined : true}
          >
            {hiddenAfter > 0 ? (
              <div className="transcript-later">
                <button type="button" className="link-btn" onClick={jump}>
                  {copy("supermux.harness.status.jumpToLatest")}
                </button>
              </div>
            ) : null}
          </div>
          {/* Interactive permission/question/plan cards live outside virtual rows,
              so keyboard focus cannot be unmounted while the user answers them. */}
          {footer}
          <div className="transcript-pad" />
        </div>
      </div>
      {showPill ? (
        <button type="button" className="jump-pill" onClick={jump}>
          <ArrowDown size={12} />
          {copy("supermux.harness.status.jumpToLatest")}
        </button>
      ) : null}
    </div>
  );
}

import { useEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";
import type { Turn } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { ArrowDown } from "../Icons";
import { Timeline } from "./Timeline";
import { TurnView } from "./TurnView";

const WINDOW_SIZE = 26;
const WINDOW_STEP = 18;

interface TranscriptListProps {
  turns: Turn[];
  scrollRef: RefObject<HTMLDivElement | null>;
  /** Observed for size changes so late-growing cards keep the bottom pinned. */
  contentRef?: RefObject<HTMLDivElement | null>;
  showPill: boolean;
  onJump: () => void;
  onRewind?: (uuid: string) => void;
  header?: ReactNode;
  footer?: ReactNode;
}

export function TranscriptList({
  turns,
  scrollRef,
  contentRef,
  showPill,
  onJump,
  onRewind,
  header,
  footer
}: TranscriptListProps) {
  const copy = useCopy();
  const [visible, setVisible] = useState(WINDOW_SIZE);
  const sentinel = useRef<HTMLDivElement>(null);
  const lastCount = useRef(turns.length);

  useEffect(() => {
    if (turns.length !== lastCount.current) {
      lastCount.current = turns.length;
      setVisible((current) => Math.max(current, WINDOW_SIZE));
    }
  }, [turns.length]);

  useEffect(() => {
    const node = sentinel.current;
    const root = scrollRef.current;
    if (!node || !root || visible >= turns.length) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setVisible((current) => Math.min(turns.length, current + WINDOW_STEP));
        }
      },
      { root, rootMargin: "600px 0px 0px 0px" }
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [scrollRef, turns.length, visible]);

  const shown = useMemo(
    () => (visible >= turns.length ? turns : turns.slice(turns.length - visible)),
    [turns, visible]
  );
  const hidden = turns.length - shown.length;

  return (
    <div className={`transcript-wrap${showPill ? " has-pill" : ""}`}>
      <div
        className="harness-scroll transcript"
        ref={scrollRef}
        tabIndex={-1}
        role="log"
        aria-label={copy("supermux.harness.a11y.transcript")}
      >
        <div className="transcript-inner" ref={contentRef}>
          {header}
          {hidden > 0 ? (
            <div ref={sentinel} className="transcript-earlier">
              <button
                type="button"
                className="link-btn"
                onClick={() => setVisible((current) => Math.min(turns.length, current + WINDOW_STEP))}
              >
                {plural(
                  copy,
                  hidden,
                  "supermux.harness.turn.earlierMessagesOne",
                  "supermux.harness.turn.earlierMessages"
                )}
              </button>
            </div>
          ) : null}
          {shown.map((turn, i) => (
            <TurnView
              key={turn.id}
              turn={turn}
              isLast={i === shown.length - 1}
              onRewind={onRewind}
            />
          ))}
          {footer}
          <div className="transcript-pad" />
        </div>
      </div>
      <Timeline turns={turns} scrollRef={scrollRef} />
      {showPill ? (
        <button type="button" className="jump-pill" onClick={onJump}>
          <ArrowDown size={12} />
          {copy("supermux.harness.status.jumpToLatest")}
        </button>
      ) : null}
    </div>
  );
}

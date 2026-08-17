import { useEffect, useRef } from "react";
import { useCopy } from "../CopyContext";
import { formatDuration } from "../format";

/**
 * One shared ticker drives every elapsed label via direct textContent writes —
 * zero React re-renders. It runs at 250ms rather than 1s because a 1s interval
 * starting at mount is unaligned to any label's start time, so the first
 * whole-second flip lands anywhere in [0,1000)ms late and the most-watched
 * number on screen visibly jumps 0s → 2s. At 250ms each label's own rounding
 * settles within a quarter second of the true tick.
 */
const TICK_MS = 250;

const subscribers = new Set<() => void>();
let ticker = 0;

function ensureTicker(): void {
  if (ticker) return;
  ticker = window.setInterval(() => {
    for (const fn of subscribers) fn();
  }, TICK_MS);
}

function releaseTicker(): void {
  if (subscribers.size > 0 || !ticker) return;
  window.clearInterval(ticker);
  ticker = 0;
}

export function Elapsed({
  startedAtMs,
  className,
  prefix,
  suffix
}: {
  startedAtMs: number;
  className?: string;
  prefix?: string;
  suffix?: string;
}) {
  const ref = useRef<HTMLSpanElement>(null);
  const copy = useCopy();

  useEffect(() => {
    let last = "";
    const write = () => {
      const node = ref.current;
      if (!node) return;
      const next = `${prefix ?? ""}${formatDuration(Date.now() - startedAtMs, copy)}${suffix ?? ""}`;
      // Only touch the DOM when the rendered second actually changed.
      if (next === last) return;
      last = next;
      node.textContent = next;
    };
    write();
    subscribers.add(write);
    ensureTicker();
    return () => {
      subscribers.delete(write);
      releaseTicker();
    };
  }, [copy, startedAtMs, prefix, suffix]);

  return <span ref={ref} className={className} />;
}

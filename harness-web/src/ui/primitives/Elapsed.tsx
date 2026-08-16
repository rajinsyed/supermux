import { useEffect, useRef } from "react";
import { formatDuration } from "../format";

const subscribers = new Set<() => void>();
let ticker = 0;

function ensureTicker(): void {
  if (ticker) return;
  ticker = window.setInterval(() => {
    for (const fn of subscribers) fn();
  }, 1000);
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

  useEffect(() => {
    const write = () => {
      const node = ref.current;
      if (!node) return;
      node.textContent = `${prefix ?? ""}${formatDuration(Date.now() - startedAtMs)}${suffix ?? ""}`;
    };
    write();
    subscribers.add(write);
    ensureTicker();
    return () => {
      subscribers.delete(write);
      releaseTicker();
    };
  }, [startedAtMs, prefix, suffix]);

  return <span ref={ref} className={className} />;
}

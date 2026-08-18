import { useCallback, useEffect, useRef, useState } from "react";
import type { ContextUsage } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { formatTokens } from "../format";

/* Sized to the strip's one icon scale (12px glyphs), not to itself: at 22px
   with a 2.6 stroke the ring was the heaviest mark on a line of quiet text and
   read as a status badge rather than as one more control. */
const SIZE = 14;
const STROKE = 2;
const RADIUS = (SIZE - STROKE) / 2;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

export function ContextRing({ usage }: { usage?: ContextUsage }) {
  const copy = useCopy();
  // Hover alone made this a button that did nothing for keyboard and touch, so
  // the breakdown opens on pointer, focus, AND click, and Escape closes it.
  const [hovered, setHovered] = useState(false);
  const [pinned, setPinned] = useState(false);
  const [focused, setFocused] = useState(false);
  const root = useRef<HTMLDivElement>(null);

  const close = useCallback(() => {
    setPinned(false);
    setHovered(false);
    setFocused(false);
  }, []);

  useEffect(() => {
    if (!pinned) return;
    const onDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) close();
    };
    window.addEventListener("mousedown", onDown);
    return () => window.removeEventListener("mousedown", onDown);
  }, [close, pinned]);

  if (!usage || !usage.maxTokens) return null;

  const open = hovered || pinned || focused;
  const percentage = Math.max(0, Math.min(100, usage.percentage ?? 0));
  const tone = percentage >= 90 ? "danger" : percentage >= 70 ? "warn" : "ok";
  const offset = CIRCUMFERENCE * (1 - percentage / 100);
  const categories = (usage.categories ?? []).filter((c) => c.tokens > 0);
  const summary = copy("supermux.harness.header.contextUsed", {
    used: formatTokens(usage.totalTokens),
    total: formatTokens(usage.maxTokens)
  });

  return (
    <div
      className="ctx"
      ref={root}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
    >
      <button
        type="button"
        className={`ctx-btn is-${tone}`}
        aria-label={`${copy("supermux.harness.header.context")} — ${summary}`}
        aria-expanded={open}
        onClick={() => setPinned((v) => !v)}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onKeyDown={(event) => {
          if (event.key === "Escape" && open) {
            event.preventDefault();
            close();
            event.currentTarget.blur();
          }
        }}
      >
        <svg width={SIZE} height={SIZE} viewBox={`0 0 ${SIZE} ${SIZE}`} aria-hidden="true">
          <circle
            cx={SIZE / 2}
            cy={SIZE / 2}
            r={RADIUS}
            fill="none"
            stroke="var(--border-strong)"
            strokeWidth={STROKE}
          />
          <circle
            className="ctx-arc"
            cx={SIZE / 2}
            cy={SIZE / 2}
            r={RADIUS}
            fill="none"
            strokeWidth={STROKE}
            strokeLinecap="round"
            strokeDasharray={CIRCUMFERENCE}
            strokeDashoffset={offset}
            transform={`rotate(-90 ${SIZE / 2} ${SIZE / 2})`}
          />
        </svg>
        <span className="ctx-value tnum">{percentage}%</span>
      </button>
      {open ? (
        <div className="ctx-pop" role="tooltip">
          <div className="ctx-pop-head">
            <span>{copy("supermux.harness.header.context")}</span>
            <span className="tnum">{summary}</span>
          </div>
          <div className="ctx-bar">
            <span className={`ctx-bar-fill is-${tone}`} style={{ width: `${percentage}%` }} />
          </div>
          {categories.length > 0 ? (
            <ul className="ctx-cats">
              {categories.map((category) => (
                <li key={category.name}>
                  <span>{category.name}</span>
                  <span className="tnum">{formatTokens(category.tokens)}</span>
                </li>
              ))}
            </ul>
          ) : null}
          {usage.isAutoCompactEnabled && usage.autoCompactThreshold ? (
            <div className="ctx-note tnum">
              {copy("supermux.harness.header.contextAutoCompact", {
                threshold: formatTokens(usage.autoCompactThreshold)
              })}
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

import { useCallback, useEffect, useRef, useState } from "react";
import type { ContextUsage } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { formatTokens } from "../format";
import { PopoverSurface } from "../primitives/Popover";

/* Sized to the strip's one icon scale (12px glyphs), not to itself: at 22px
   with a 2.6 stroke the ring was the heaviest mark on a line of quiet text and
   read as a status badge rather than as one more control. */
const SIZE = 14;
const STROKE = 2;
const RADIUS = (SIZE - STROKE) / 2;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

/**
 * The context breakdown.
 *
 * The panel is one figure — how much of the window is gone — and then the
 * accounting behind it. The headline is the PERCENTAGE at display size with the
 * token count under it, because "83%" is the thing a reader is deciding on and
 * "142.1k of 200k" is the evidence; the previous build put both on one 12px row
 * where neither was the answer. Every category gets its own share bar so the
 * one line that is actually eating the window is visible without reading five
 * numbers and comparing them.
 */
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
  // Shares are of the WINDOW, not of the accounted total: a bar that fills the
  // row because it is the largest of three small categories would overstate a
  // 4k system prompt in a 200k window.
  const largest = categories.reduce((max, c) => Math.max(max, c.tokens), 0);
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
        <PopoverSurface className={`pop-ctx is-${tone}`} role="tooltip">
          <div className="ctx-pop-head">
            <span className="ctx-pop-label">{copy("supermux.harness.header.context")}</span>
            <span className="ctx-pop-figure tnum">{percentage}%</span>
            <span className="ctx-pop-sub tnum">{summary}</span>
          </div>

          <div className="ctx-bar">
            <span className={`ctx-bar-fill is-${tone}`} style={{ width: `${percentage}%` }} />
          </div>

          {categories.length > 0 ? (
            <ul className="ctx-cats">
              {categories.map((category) => (
                <li key={category.name} className="ctx-cat">
                  <span className="ctx-cat-name">{category.name}</span>
                  <span className="ctx-cat-track" aria-hidden="true">
                    <span
                      className="ctx-cat-fill"
                      style={{
                        width: `${largest > 0 ? Math.max(3, (category.tokens / largest) * 100) : 0}%`
                      }}
                    />
                  </span>
                  <span className="ctx-cat-value tnum">{formatTokens(category.tokens)}</span>
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
        </PopoverSurface>
      ) : null}
    </div>
  );
}

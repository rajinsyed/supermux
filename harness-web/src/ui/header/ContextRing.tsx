import { useState } from "react";
import type { ContextUsage } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { formatTokens } from "../format";

const SIZE = 22;
const STROKE = 2.6;
const RADIUS = (SIZE - STROKE) / 2;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

export function ContextRing({ usage }: { usage?: ContextUsage }) {
  const copy = useCopy();
  const [open, setOpen] = useState(false);
  if (!usage || !usage.maxTokens) return null;

  const percentage = Math.max(0, Math.min(100, usage.percentage ?? 0));
  const tone = percentage >= 90 ? "danger" : percentage >= 70 ? "warn" : "ok";
  const offset = CIRCUMFERENCE * (1 - percentage / 100);
  const categories = (usage.categories ?? []).filter((c) => c.tokens > 0);

  return (
    <div
      className="ctx"
      onMouseEnter={() => setOpen(true)}
      onMouseLeave={() => setOpen(false)}
    >
      <button
        type="button"
        className={`ctx-btn is-${tone}`}
        aria-label={copy("supermux.harness.header.contextUsed", {
          used: formatTokens(usage.totalTokens),
          total: formatTokens(usage.maxTokens)
        })}
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
            <span className="tnum">
              {copy("supermux.harness.header.contextUsed", {
                used: formatTokens(usage.totalTokens),
                total: formatTokens(usage.maxTokens)
              })}
            </span>
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

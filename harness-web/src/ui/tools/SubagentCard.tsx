import { memo, useState } from "react";
import type { Block, ToolBlock } from "../../model/types";
import { useCopy } from "../CopyContext";
import { AlertTriangle, CheckCircle, ChevronDown, ChevronRight, Layers } from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { ToolCard } from "./ToolCard";

function ChildBlock({ block, depth }: { block: Block; depth: number }) {
  if (block.kind === "tool") return <ToolCard block={block} depth={depth} />;
  if (block.kind === "notice") return <div className="subagent-note">{block.text}</div>;
  return null;
}

export const SubagentCard = memo(function SubagentCard({
  block,
  depth = 0
}: {
  block: ToolBlock;
  depth?: number;
}) {
  const copy = useCopy();
  const info = block.subagent ?? {};
  const running = block.status === "running" || block.status === "pending";
  const [open, setOpen] = useState(false);

  const description = info.description ?? (block.input.description as string) ?? block.name;
  const type = info.subagentType ?? (block.input.subagent_type as string);
  const metrics: string[] = [];
  if (info.totalTokens) metrics.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(info.totalTokens) }));
  if (info.toolUses) metrics.push(copy("supermux.harness.subagent.toolUses", { count: info.toolUses }));
  if (info.durationMs) metrics.push(formatCompactDuration(info.durationMs));

  const activity = running ? info.activity ?? info.lastToolName : info.summary;

  return (
    <div className={`subagent-card is-${block.status}`}>
      <div className="subagent-head">
        <span className="subagent-icon">
          <Layers size={13} />
        </span>
        <span className="subagent-identity">
          <span className="subagent-name">{description}</span>
          <span className="subagent-meta">
            {type ? <span className="subagent-type">{type}</span> : null}
            {info.background ? (
              <span className="tool-badge is-quiet">{copy("supermux.harness.subagent.background")}</span>
            ) : null}
            {metrics.length > 0 ? <span className="tnum">{metrics.join(" · ")}</span> : null}
          </span>
        </span>
        {running ? (
          <>
            <Elapsed className="tool-elapsed tnum" startedAtMs={block.startedAtMs} />
            <Spinner size={12} />
          </>
        ) : block.status === "error" ? (
          <AlertTriangle size={13} className="mark-warn" />
        ) : (
          <CheckCircle size={13} className="mark-ok" />
        )}
      </div>
      <div className="subagent-activity">{activity ?? " "}</div>
      {block.children.length > 0 ? (
        <>
          <button
            type="button"
            className="subagent-toggle"
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
          >
            {open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
            {open
              ? copy("supermux.harness.subagent.hideTranscript")
              : copy("supermux.harness.subagent.showTranscript")}
          </button>
          <Disclosure open={open} className="subagent-children">
            {block.children.map((child) => (
              <ChildBlock key={child.key} block={child} depth={depth + 1} />
            ))}
          </Disclosure>
        </>
      ) : null}
    </div>
  );
});

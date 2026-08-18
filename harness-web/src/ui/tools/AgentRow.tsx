import { memo, useContext } from "react";
import { workStartedAtMs } from "../../model/tasks";
import type { Block, ToolBlock } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { ChevronRight, Layers } from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Elapsed } from "../primitives/Elapsed";
import { toolStatsSummary } from "./toolStats";
import { OpenViewContext } from "../views/OpenViewContext";

/**
 * The inline surface for an agent, in one line.
 *
 * Round 3 drew a full expandable card here — a nested tree of the agent's whole
 * conversation, inline, inside the turn that spawned it. The user's verdict was
 * that this is not how the CLI reads: the transcript should say THAT an agent
 * ran and how it went, and the conversation itself belongs in the agent's own
 * view, reachable in one click. So this row carries exactly what a reader
 * scanning the transcript needs — is it running, what was it for, what did it
 * cost — and opens the full chat.
 *
 * Children nest one level with a `└` guide, matching the dock's tree, so the
 * shape of a nested spawn is visible without descending into it.
 */
function childAgents(block: ToolBlock): ToolBlock[] {
  const out: ToolBlock[] = [];
  const walk = (blocks: Block[]) => {
    for (const child of blocks) {
      if (child.kind !== "tool") continue;
      if (child.name === "Task" || child.name === "Agent") {
        out.push(child);
        continue;
      }
      walk(child.children);
    }
  };
  walk(block.children);
  return out;
}

function dotClass(block: ToolBlock): string {
  const status = block.subagent?.status;
  if (status === "failed" || block.status === "error") return "is-error";
  if (status === "killed" || status === "stopped") return "is-stopped";
  if (block.status === "running" || block.status === "pending") return "is-running";
  return "is-done";
}

export const AgentRow = memo(function AgentRow({
  block,
  nested = false
}: {
  block: ToolBlock;
  /** Rendered under its parent agent's row, with the tree guide. */
  nested?: boolean;
}) {
  const copy = useCopy();
  const openView = useContext(OpenViewContext);
  const info = block.subagent ?? {};
  const running = block.status === "running" || block.status === "pending";
  const description =
    info.description ?? (block.input.description as string | undefined) ?? block.name;
  const type = info.subagentType ?? (block.input.subagent_type as string | undefined);

  const metrics: string[] = [];
  if (info.totalTokens) {
    metrics.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(info.totalTokens) }));
  }
  if (info.toolUses) {
    metrics.push(
      plural(
        copy,
        info.toolUses,
        "supermux.harness.subagent.toolUsesOne",
        "supermux.harness.subagent.toolUses"
      )
    );
  }
  if (!running && info.durationMs) metrics.push(formatCompactDuration(info.durationMs, copy));

  const children = childAgents(block);
  const stats = !running && info.toolStats ? toolStatsSummary(info.toolStats, copy) : [];

  return (
    <div className={`agent-row-wrap${nested ? " is-nested" : ""}`}>
      <button
        type="button"
        className={`agent-row is-${block.status}`}
        onClick={() => openView({ kind: "agent", toolUseId: block.toolUseId })}
      >
        {nested ? <span className="agent-row-guide" aria-hidden="true" /> : null}
        <span className={`dock-dot ${dotClass(block)}`} aria-hidden="true" />
        <span className="agent-row-icon" aria-hidden="true">
          <Layers size={12} />
        </span>
        <span className="agent-row-name" title={description}>
          {description}
        </span>
        {type ? <span className="agent-row-type">{type}</span> : null}
        {/* While it runs, WHAT it is doing is the useful field; once it is done,
            what it concluded is. Same slot, because they are the same question
            asked at two moments. */}
        <span className="agent-row-activity">
          {running
            ? info.activity ??
              info.lastToolName ??
              copy("supermux.harness.subagent.waiting")
            : info.summary ?? ""}
        </span>
        <span className="agent-row-spacer" />
        {/* How many agents this one started, so the tree's SHAPE is legible
            from the row even before the nested rows below it are scanned. */}
        {children.length > 0 ? (
          <span className="agent-row-nested">
            {plural(
              copy,
              children.length,
              "supermux.harness.subagent.nestedOne",
              "supermux.harness.subagent.nested"
            )}
          </span>
        ) : null}
        {metrics.length > 0 ? <span className="agent-row-metrics tnum">{metrics.join(" · ")}</span> : null}
        {running ? (
          <Elapsed className="agent-row-elapsed tnum" startedAtMs={workStartedAtMs(block)} />
        ) : null}
        <span className="agent-row-open">
          {copy("supermux.harness.dock.open")}
          <ChevronRight size={10} />
        </span>
      </button>
      {/* What it changed, on the line under the row: a summary in the metrics
          slot would push the elapsed and the Open affordance off a narrow
          pane, and "edited 3 files · +40 −7" is the kind of thing a reader
          scans for on its own line anyway. */}
      {stats.length > 0 ? <div className="agent-row-stats tnum">{stats.join(" · ")}</div> : null}
      {children.map((child) => (
        <AgentRow key={child.key} block={child} nested />
      ))}
    </div>
  );
});

import { memo, useState } from "react";
import type { CopyFn } from "../CopyContext";
import type { Block, SubagentToolStats, ToolBlock } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { AlertTriangle, CheckCircle, ChevronDown, ChevronRight, Cpu, Layers } from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { SubagentTranscriptView } from "./SubagentTranscript";
import { ToolCard } from "./ToolCard";

/**
 * How deep the tree still indents. Nesting is unbounded — an agent may spawn an
 * agent that spawns an agent — and at 21px a step a depth-6 chain has pushed its
 * content off a split pane entirely. Past the cap the rail still draws (so the
 * hierarchy is legible) but the content stops moving right.
 */
const MAX_INDENT_DEPTH = 3;

function ChildBlock({ block, depth }: { block: Block; depth: number }) {
  if (block.kind === "tool") return <ToolCard block={block} depth={depth} />;
  if (block.kind === "notice") return <div className="subagent-note">{block.text}</div>;
  return null;
}

/**
 * What the agent actually DID, from AgentOutput.toolStats — the one summary the
 * CLI has and the pane used to throw away. Ordered by what a reader scans for
 * first: what changed, then what was looked at.
 */
export function toolStatsSummary(stats: SubagentToolStats, copy: CopyFn): string[] {
  const out: string[] = [];
  if (stats.editFileCount) {
    out.push(
      plural(
        copy,
        stats.editFileCount,
        "supermux.harness.subagent.filesEditedOne",
        "supermux.harness.subagent.filesEdited"
      )
    );
  }
  if (stats.linesAdded || stats.linesRemoved) {
    out.push(
      copy("supermux.harness.subagent.lineDelta", {
        added: stats.linesAdded ?? 0,
        removed: stats.linesRemoved ?? 0
      })
    );
  }
  if (stats.readCount) {
    out.push(
      plural(
        copy,
        stats.readCount,
        "supermux.harness.subagent.filesReadOne",
        "supermux.harness.subagent.filesRead"
      )
    );
  }
  if (stats.searchCount) {
    out.push(
      plural(
        copy,
        stats.searchCount,
        "supermux.harness.subagent.searchesOne",
        "supermux.harness.subagent.searches"
      )
    );
  }
  if (stats.bashCount) {
    out.push(
      plural(
        copy,
        stats.bashCount,
        "supermux.harness.subagent.commandsOne",
        "supermux.harness.subagent.commands"
      )
    );
  }
  return out;
}

function countNested(blocks: Block[]): number {
  let count = 0;
  for (const block of blocks) {
    if (block.kind !== "tool") continue;
    if (block.name === "Task" || block.name === "Agent") count += 1;
    count += countNested(block.children);
  }
  return count;
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
  const [openChildren, setOpenChildren] = useState(false);
  const [openDrill, setOpenDrill] = useState(false);

  const description = info.description ?? (block.input.description as string) ?? block.name;
  const type = info.subagentType ?? (block.input.subagent_type as string);
  const metrics: string[] = [];
  if (info.totalTokens) metrics.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(info.totalTokens) }));
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
  if (info.durationMs) metrics.push(formatCompactDuration(info.durationMs, copy));

  const stats = !running && info.toolStats ? toolStatsSummary(info.toolStats, copy) : [];
  const activity = running
    ? info.activity ?? info.lastToolName ?? copy("supermux.harness.subagent.waiting")
    : info.summary;
  const nested = countNested(block.children);
  // The drill-in is keyed on the agent's own id. `taskId` arrives on
  // system/task_started frames — which a transcript replayed OFF DISK never
  // contains — while `agentId` arrives on the tool_use_result the disk file
  // does carry, and the two are the same identifier (the CLI names the file
  // agent-<taskId>.jsonl and reports that id as AgentOutput.agentId). Without
  // the fallback, drilling dead-ends at depth 1: no card inside a loaded
  // transcript could recurse.
  const drillId = info.taskId ?? info.agentId;
  const drillTarget = { taskId: drillId };
  const canDrill = drillId !== undefined;
  const indent = Math.min(depth, MAX_INDENT_DEPTH);

  return (
    <div className={`subagent-card is-${block.status}`} data-depth={indent}>
      <div className="subagent-head">
        <span className="subagent-icon">
          <Layers size={13} />
        </span>
        <span className="subagent-identity">
          <span className="subagent-name">{description}</span>
          <span className="subagent-meta">
            <span className="tool-badge is-quiet">{copy("supermux.harness.subagent.badge")}</span>
            {type ? <span className="subagent-type">{type}</span> : null}
            {info.model ? (
              <span className="subagent-model" title={info.model}>
                <Cpu size={9} />
                <span className="subagent-model-name">{info.model}</span>
              </span>
            ) : null}
            {info.background ? (
              <span className="tool-badge is-quiet">{copy("supermux.harness.subagent.background")}</span>
            ) : null}
            {nested > 0 ? (
              <span className="tool-badge is-quiet">
                {plural(copy, nested, "supermux.harness.subagent.nestedOne", "supermux.harness.subagent.nested")}
              </span>
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
      <div className="subagent-activity">{activity ?? " "}</div>
      {stats.length > 0 ? <div className="subagent-stats tnum">{stats.join(" · ")}</div> : null}
      <div className="subagent-actions">
        {block.children.length > 0 ? (
          <button
            type="button"
            className="subagent-toggle"
            onClick={() => setOpenChildren((v) => !v)}
            aria-expanded={openChildren}
          >
            {openChildren ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
            {openChildren
              ? copy("supermux.harness.subagent.hideTranscript")
              : copy("supermux.harness.subagent.showTranscript")}
          </button>
        ) : null}
        {canDrill ? (
          <button
            type="button"
            className="subagent-toggle is-drill"
            onClick={() => setOpenDrill((v) => !v)}
            aria-expanded={openDrill}
          >
            {openDrill ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
            {openDrill
              ? copy("supermux.harness.subagent.closeTranscript")
              : copy("supermux.harness.subagent.openTranscript")}
          </button>
        ) : null}
      </div>
      {block.children.length > 0 ? (
        <Disclosure open={openChildren} className="subagent-children">
          {block.children.map((child) => (
            <ChildBlock key={child.key} block={child} depth={depth + 1} />
          ))}
        </Disclosure>
      ) : null}
      {canDrill ? (
        <Disclosure open={openDrill} className="subagent-drill">
          <SubagentTranscriptView
            target={drillTarget}
            label={description}
            open={openDrill}
            // Only while it still runs: a settled agent's file never changes
            // again, and re-fetching it on every later frame is pure churn.
            tick={running ? info.progressTick : undefined}
          />
        </Disclosure>
      ) : null}
    </div>
  );
});

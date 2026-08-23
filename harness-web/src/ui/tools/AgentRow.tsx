import { memo, useContext } from "react";
import { isTaskSettled } from "../../model/tasks";
import type { Block, ToolBlock } from "../../model/types";
import { useCopy } from "../CopyContext";
import { ChevronRight } from "../Icons";
import { WorkingGlyph } from "../primitives/Spinner";
import { toolStatsSummary } from "./toolStats";
import { OpenViewContext } from "../views/OpenViewContext";

/**
 * The inline surface for an agent: the reference's quiet two-line row.
 *
 *   ● Logic test agent   general-purpose
 *     Completed
 *
 * A dot carries the state, the name is plain ink, the type is dim text beside
 * it, and the second line is one phrase — the live activity while it runs, the
 * outcome word or summary once it is done. No icons, no metric chips: the
 * numbers live in the agent's own view, one click away. Children nest with an
 * indent, matching the working panel's tree.
 */
function childAgents(block: ToolBlock): ToolBlock[] {
  const out: ToolBlock[] = [];
  const walk = (blocks: Block[]) => {
    for (const child of blocks) {
      if (child.kind !== "tool") continue;
      if (child.name === "Task" || child.name === "Agent") {
        // A failed attempt a later retry superseded is that retry's history,
        // not a sibling agent.
        if (child.supersededByToolUseId === undefined) out.push(child);
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
  /** Rendered under its parent agent's row, indented one step. */
  nested?: boolean;
}) {
  const copy = useCopy();
  const openView = useContext(OpenViewContext);
  const info = block.subagent ?? {};
  // An async agent's launch call settles with "async_launched" while the agent
  // itself keeps running — the tool status alone would show a done dot on live
  // work. The subagent's own task status is authoritative once present.
  const running =
    block.status === "running" ||
    block.status === "pending" ||
    (info.status !== undefined && !isTaskSettled(info.status));
  const inputDescription =
    typeof block.input.description === "string" ? block.input.description : undefined;
  const inputType =
    typeof block.input.subagent_type === "string" ? block.input.subagent_type : undefined;
  const description = info.description ?? inputDescription ?? block.name;
  const type = info.subagentType ?? inputType;

  /**
   * The second line, as ONE phrase. While it runs: what it is doing right now.
   * Settled: its summary when one arrived, else the plain outcome word — and
   * "what it changed" appended when the stats carry real news.
   */
  const statusWord =
    info.status === "failed" || block.status === "error"
      ? copy("supermux.harness.tool.failed")
      : info.status === "killed" || info.status === "stopped"
        ? copy("supermux.harness.bash.statusKilled")
        : copy("supermux.harness.tool.succeeded");
  const stats = !running && info.toolStats ? toolStatsSummary(info.toolStats, copy) : [];
  const line = running
    ? info.activity ?? info.lastToolName ?? copy("supermux.harness.subagent.waiting")
    : info.summary ?? (stats.length > 0 ? `${statusWord} · ${stats.join(" · ")}` : statusWord);

  const children = childAgents(block);

  return (
    <div className={`agent-row-wrap${nested ? " is-nested" : ""}`}>
      <button
        type="button"
        className={`agent-row is-${running ? "running" : block.status}`}
        onClick={() => openView({ kind: "agent", toolUseId: block.toolUseId })}
      >
        {/* The reference's marks: the drifting constellation while it runs, a
            settled dot once it is done. */}
        {running ? (
          <WorkingGlyph className="agent-row-glyph" />
        ) : (
          <span className={`agent-dot ${dotClass(block)}`} aria-hidden="true" />
        )}
        <span className="agent-row-main">
          <span className="agent-row-head">
            <span className="agent-row-name" title={description}>
              {description}
            </span>
            {type ? <span className="agent-row-type">{type}</span> : null}
            <span className="agent-row-spacer" />
            <ChevronRight size={11} className="agent-row-chev" aria-hidden="true" />
          </span>
          <span className="agent-row-activity" title={line}>
            {line}
          </span>
        </span>
      </button>
      {children.map((child) => (
        <AgentRow key={child.key} block={child} nested />
      ))}
    </div>
  );
});

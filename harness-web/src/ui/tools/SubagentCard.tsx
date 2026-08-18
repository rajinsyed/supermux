import { createContext, memo, useContext, useMemo, useState } from "react";
import type { CopyFn } from "../CopyContext";
import { workStartedAtMs } from "../../model/tasks";
import type { Block, SubagentToolStats, ToolBlock } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { AlertTriangle, CheckCircle, ChevronDown, ChevronRight, Cpu, Layers } from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { useDismissible } from "../primitives/useDismissible";
import { useFoldHold } from "../transcript/foldGuard";
import { SubagentTranscriptView } from "./SubagentTranscript";
import { ToolCard } from "./ToolCard";

/**
 * The agents this card is ALREADY showing inline, so its own drill-in does not
 * render them a second time.
 *
 * A card's inline children are the frames this session streamed; its drill-in is
 * the same agent's file on disk — and that file contains the very same nested
 * `tool_use` blocks. So opening a drill-in on an agent that spawned another drew
 * the child agent twice inside one card, the two copies wearing slightly
 * different chips (the disk copy has an `agentId` but no task frames, so no live
 * metrics), which reads as two agents that did the same work rather than one
 * seen from two places.
 */
const InlineAgents = createContext<ReadonlySet<string>>(new Set());

/**
 * Every id one agent card answers to. `toolUseId` is what the wire nests by,
 * `taskId` is what the task frames carry, and `agentId` is what an off-disk
 * transcript has instead — the same agent arrives under different ones
 * depending on which source rendered it.
 */
function identitiesOf(block: ToolBlock): string[] {
  const out = [block.toolUseId, block.subagent?.taskId, block.subagent?.agentId];
  return out.filter((id): id is string => typeof id === "string" && id.length > 0);
}

function collectAgents(blocks: Block[], into: Set<string>): void {
  for (const block of blocks) {
    if (block.kind !== "tool") continue;
    if (block.name === "Task" || block.name === "Agent") {
      for (const id of identitiesOf(block)) into.add(id);
    }
    collectAgents(block.children, into);
  }
}

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

/** True when this agent card is already rendered elsewhere in the same card. */
export function useAlreadyRendered(block: ToolBlock): boolean {
  const rendered = useContext(InlineAgents);
  return identitiesOf(block).some((id) => rendered.has(id));
}

/**
 * The stand-in for an agent whose full card is already on screen: it says the
 * work happened and where its detail is, without redrawing the card. One agent,
 * one card — the drill-in is a different SOURCE for the same events, not more
 * events.
 */
export function DuplicateAgentRow({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const info = block.subagent ?? {};
  const description = info.description ?? (block.input.description as string) ?? block.name;
  return (
    <div className="subagent-dup" title={description}>
      <Layers size={11} />
      <span className="subagent-dup-name">{description}</span>
      <span className="subagent-dup-note">
        {copy("supermux.harness.subagent.shownAbove")}
      </span>
    </div>
  );
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
  // Escape closes this drill-in, through the one contract every inline
  // disclosure in the pane now shares.
  const scope = useDismissible(openDrill, () => setOpenDrill(false));
  // Either disclosure is the reader's place in this turn, so the turn must not
  // fold itself away around it when the agent finishes.
  useFoldHold(openDrill || openChildren);

  const inherited = useContext(InlineAgents);
  /**
   * What the INLINE children may not redraw: whatever an ancestor already shows,
   * plus this card itself. The children are the frames this session streamed —
   * they are the canonical copy of the nested agents, so they must never be the
   * side that gets collapsed to a marker.
   */
  const forChildren = useMemo(() => {
    const set = new Set(inherited);
    // An agent's own transcript opens with its own prompt, so the recursion must
    // not offer to draw the card it is already inside.
    for (const id of identitiesOf(block)) set.add(id);
    return set;
  }, [block, inherited]);
  /**
   * What the DRILL-IN may not redraw: all of the above plus the inline children,
   * which is the whole point — the agent's file on disk contains the same nested
   * `tool_use` blocks the children already rendered, and drawing both put two
   * full cards for one agent inside one card, wearing different chips.
   */
  const forDrill = useMemo(() => {
    const set = new Set(forChildren);
    collectAgents(block.children, set);
    return set;
  }, [block.children, forChildren]);

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
    <div
      className={`subagent-card is-${block.status}`}
      data-depth={indent}
      ref={scope as React.RefObject<HTMLDivElement>}
    >
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
            {/* One clock: the task record's start, so this card and the agent's
                row in the tasks strip never report different elapsed. */}
            <Elapsed className="tool-elapsed tnum" startedAtMs={workStartedAtMs(block)} />
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
      {/* Two scopes, because the two disclosures are not symmetric: the inline
          children are the canonical rendering of the nested agents, and the
          drill-in is the same events read back off disk. So the children only
          avoid what an ANCESTOR already draws, while the drill-in additionally
          avoids the children. */}
      {block.children.length > 0 ? (
        <InlineAgents.Provider value={forChildren}>
          <Disclosure open={openChildren} className="subagent-children">
            {block.children.map((child) => (
              <ChildBlock key={child.key} block={child} depth={depth + 1} />
            ))}
          </Disclosure>
        </InlineAgents.Provider>
      ) : null}
      {canDrill ? (
        <InlineAgents.Provider value={forDrill}>
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
        </InlineAgents.Provider>
      ) : null}
    </div>
  );
});

import { createContext, useContext, useMemo } from "react";
import type { Block, TranscriptModel } from "../../model/types";
import { useCopy } from "../CopyContext";
import { ChevronRight, Refresh } from "../Icons";
import { Spinner } from "../primitives/Spinner";
import {
  useSubagentTranscriptResource,
  type SubagentTranscriptTarget
} from "../subagentTranscriptResource";
import { BlockView } from "../transcript/BlockView";

/**
 * The chain of agents descended through to reach the current drill-in.
 *
 * Drilling recurses to arbitrary depth — an agent card inside a loaded
 * transcript drills again with the same affordance — and three levels down the
 * reader needs to know WHERE they are. Each drill-in appends its own label and
 * renders the accumulated trail as a breadcrumb in its header.
 */
const DrillTrail = createContext<string[]>([]);

export type SubagentTranscriptKey = SubagentTranscriptTarget;

type State = {
  identity: string;
  phase: "loading" | "ready" | "missing" | "failed";
  model?: TranscriptModel;
  sourceGeneration: number;
  truncated: boolean;
  meta?: { agentType?: string; description?: string; spawnDepth?: number };
};

/**
 * The agent's own transcript, replayed through the pane's shared isolated
 * transcript resource. Every consumer of this target observes the same reducer,
 * revision cursor, and in-flight native request.
 */
export function useSubagentTranscript(
  key: SubagentTranscriptKey,
  open: boolean,
  tick: number | undefined
): State & { reload(): void } {
  return useSubagentTranscriptResource(key, open, tick);
}

function blocksOf(model: TranscriptModel): Block[] {
  const out: Block[] = [];
  for (const turn of model.turns) {
    if (turn.userText) {
      out.push({
        kind: "notice",
        key: `${turn.id}:prompt`,
        level: "info",
        text: turn.userText
      });
    }
    for (const block of turn.blocks) {
      // A failed attempt a later retry superseded is that retry's history.
      if (block.kind === "tool" && block.supersededByToolUseId !== undefined) continue;
      out.push(block);
    }
  }
  return out;
}

export function SubagentTranscriptView({
  target,
  open,
  tick,
  label
}: {
  target: SubagentTranscriptKey;
  open: boolean;
  /** Bumped by the reducer on every task frame; drives the live re-fetch. */
  tick?: number;
  /** This agent's name in the breadcrumb trail of a nested descent. */
  label?: string;
}) {
  const copy = useCopy();
  const state = useSubagentTranscript(target, open, tick);
  const parentTrail = useContext(DrillTrail);
  const trail = useMemo(() => {
    const own =
      label ?? state.meta?.description ?? target.agentId ?? target.taskId ?? "";
    return own ? [...parentTrail, own] : parentTrail;
  }, [label, parentTrail, state.meta?.description, target.agentId, target.taskId]);

  if (state.phase === "loading") {
    return (
      <div className="drill-status">
        <Spinner size={12} />
        {copy("supermux.harness.subagent.transcriptLoading")}
      </div>
    );
  }
  if (state.phase === "missing") {
    return <div className="drill-status">{copy("supermux.harness.subagent.transcriptMissing")}</div>;
  }
  if (state.phase === "failed") {
    return (
      <div className="drill-status is-error">
        {copy("supermux.harness.subagent.transcriptFailed")}
        <button type="button" className="link-btn" onClick={state.reload}>
          <Refresh size={11} />
          {copy("supermux.harness.subagent.transcriptRefresh")}
        </button>
      </div>
    );
  }

  const blocks = state.model ? blocksOf(state.model) : [];
  if (blocks.length === 0) {
    return <div className="drill-status">{copy("supermux.harness.subagent.transcriptEmpty")}</div>;
  }

  return (
    <>
      {/* The drill-in and the card's inline children render with the SAME block
          renderers and sit inside the same card, so without this they are
          indistinguishable — and they are not the same thing. The children are
          the frames this session streamed; this is the agent's own file on
          disk, which is deeper, may be truncated, and keeps growing while the
          agent runs. */}
      <div className="drill-head">
        <span className="drill-source">{copy("supermux.harness.subagent.fromDisk")}</span>
        {trail.length > 1 ? (
          <span className="drill-trail" title={trail.join(" › ")}>
            {trail.map((step, i) => (
              <span key={`${i}:${step}`} className="drill-trail-step">
                {i > 0 ? <ChevronRight size={8} /> : null}
                {step}
              </span>
            ))}
          </span>
        ) : null}
        {state.meta?.agentType ? (
          <span className="drill-agent-type">{state.meta.agentType}</span>
        ) : null}
        {state.truncated ? (
          <span className="drill-note">
            {copy("supermux.harness.subagent.transcriptTruncated")}
          </span>
        ) : null}
        {state.meta?.spawnDepth !== undefined && state.meta.spawnDepth > 0 ? (
          <span className="drill-note">
            {copy("supermux.harness.subagent.spawnDepth", { depth: state.meta.spawnDepth })}
          </span>
        ) : null}
      </div>
      <div className="drill-transcript">
        <DrillTrail.Provider value={trail}>
          {blocks.map((block) => (
            <BlockView
              key={block.key}
              block={block}
              generation={state.sourceGeneration}
            />
          ))}
        </DrillTrail.Provider>
      </div>
    </>
  );
}

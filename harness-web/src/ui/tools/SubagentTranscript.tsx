import { useCallback, useEffect, useRef, useState } from "react";
import { getBridge } from "../../bridge";
import { replayLines } from "../../model/transcript";
import type { Block, TranscriptModel } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Refresh } from "../Icons";
import { Spinner } from "../primitives/Spinner";
import { BlockView } from "../transcript/BlockView";

export interface SubagentTranscriptKey {
  taskId?: string;
  workflowRunId?: string;
  agentId?: string;
}

type Phase = "loading" | "ready" | "missing" | "failed";

interface State {
  phase: Phase;
  model?: TranscriptModel;
  truncated: boolean;
  meta?: { agentType?: string; description?: string; spawnDepth?: number };
}

function keyOf(key: SubagentTranscriptKey): string {
  return `${key.taskId ?? ""}|${key.workflowRunId ?? ""}|${key.agentId ?? ""}`;
}

/**
 * The agent's own transcript, replayed through an ISOLATED reducer instance.
 *
 * `replayLines` builds a private model and a private index, so nothing here can
 * reach the pane's transcript: the agent's frames carry the same `tool_use_id`s
 * and turn uuids as the main session's, and folding them into the live model
 * would attach a subagent's Bash card to the parent turn that spawned it.
 *
 * While the agent runs the view re-fetches on `tick` — the progress counter the
 * reducer bumps on every task frame for this id, which the CLI emits every few
 * seconds. That is deliberately web-driven: it costs one bridge call per tick
 * only while a drill-in is actually open, and needs no native file watcher.
 */
export function useSubagentTranscript(
  key: SubagentTranscriptKey,
  open: boolean,
  tick: number | undefined
): State & { reload(): void } {
  const [state, setState] = useState<State>({ phase: "loading", truncated: false });
  const [manual, setManual] = useState(0);
  const identity = keyOf(key);
  const live = useRef(true);

  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);

  useEffect(() => {
    if (!open) return;
    if (!key.taskId && !(key.workflowRunId && key.agentId)) {
      setState({ phase: "missing", truncated: false });
      return;
    }
    let cancelled = false;
    // Not a reset to `loading`: a re-fetch on a progress tick would blank a
    // transcript the user is reading several times a minute. The first load has
    // nothing to blank, and every later one swaps content in place.
    getBridge()
      .loadSubagentTranscript({
        taskId: key.taskId,
        workflowRunId: key.workflowRunId,
        agentId: key.agentId
      })
      .then((result) => {
        if (cancelled || !live.current) return;
        if (result.missing) {
          setState({ phase: "missing", truncated: false, meta: result.meta });
          return;
        }
        setState({
          phase: "ready",
          model: replayLines(result.events ?? []),
          truncated: result.truncated === true,
          meta: result.meta
        });
      })
      .catch(() => {
        if (cancelled || !live.current) return;
        setState((previous) =>
          // A failed refresh must not throw away a transcript that already
          // rendered; only a failed FIRST load has nothing better to show.
          previous.phase === "ready" ? previous : { phase: "failed", truncated: false }
        );
      });
    return () => {
      cancelled = true;
    };
  }, [identity, key.agentId, key.taskId, key.workflowRunId, manual, open, tick]);

  const reload = useCallback(() => setManual((value) => value + 1), []);
  return { ...state, reload };
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
    for (const block of turn.blocks) out.push(block);
  }
  return out;
}

export function SubagentTranscriptView({
  target,
  open,
  tick
}: {
  target: SubagentTranscriptKey;
  open: boolean;
  /** Bumped by the reducer on every task frame; drives the live re-fetch. */
  tick?: number;
}) {
  const copy = useCopy();
  const state = useSubagentTranscript(target, open, tick);

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
        {blocks.map((block) => (
          <BlockView key={block.key} block={block} />
        ))}
      </div>
    </>
  );
}

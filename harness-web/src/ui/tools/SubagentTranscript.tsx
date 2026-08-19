import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react";
import { getBridge } from "../../bridge";
import { replayLines } from "../../model/transcript";
import type { Block, TranscriptModel } from "../../model/types";
import { useCopy } from "../CopyContext";
import { ChevronRight, Refresh } from "../Icons";
import { Spinner } from "../primitives/Spinner";
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

export interface SubagentTranscriptKey {
  taskId?: string;
  workflowRunId?: string;
  agentId?: string;
}

type Phase = "loading" | "ready" | "missing" | "failed";

interface State {
  identity: string;
  phase: Phase;
  model?: TranscriptModel;
  sourceGeneration: number;
  truncated: boolean;
  meta?: { agentType?: string; description?: string; spawnDepth?: number };
}

function keyOf(key: SubagentTranscriptKey): string {
  return `${key.taskId ?? ""}|${key.workflowRunId ?? ""}|${key.agentId ?? ""}`;
}

function loadingState(identity: string, sourceGeneration: number): State {
  return {
    identity,
    phase: "loading",
    sourceGeneration,
    truncated: false
  };
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
  const identity = keyOf(key);
  const [state, setState] = useState<State>(() => loadingState(identity, 0));
  const [manual, setManual] = useState(0);
  const live = useRef(true);
  const latestRequest = useRef(0);

  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);

  useEffect(() => {
    if (!open) return;
    const requestId = latestRequest.current + 1;
    latestRequest.current = requestId;
    const transitionIdentity = (previous: State): State =>
      previous.identity === identity
        ? previous
        : loadingState(identity, previous.sourceGeneration + 1);

    if (!key.taskId && !(key.workflowRunId && key.agentId)) {
      setState((previous) => {
        const current = transitionIdentity(previous);
        return {
          identity,
          phase: "missing",
          sourceGeneration: current.sourceGeneration,
          truncated: false
        };
      });
      return;
    }

    // A different target clears synchronously through the derived return value
    // below and is committed here. A same-target tick keeps the ready snapshot
    // visible while its refresh is pending.
    setState(transitionIdentity);
    let cancelled = false;
    getBridge()
      .loadSubagentTranscript({
        taskId: key.taskId,
        workflowRunId: key.workflowRunId,
        agentId: key.agentId
      })
      .then((result) => {
        if (cancelled || !live.current || latestRequest.current !== requestId) return;
        setState((previous) => {
          if (previous.identity !== identity) return previous;
          if (result.missing) {
            return {
              identity,
              phase: "missing",
              sourceGeneration: previous.sourceGeneration,
              truncated: false,
              meta: result.meta
            };
          }
          return {
            identity,
            phase: "ready",
            model: replayLines(result.events ?? []),
            sourceGeneration: previous.sourceGeneration + 1,
            truncated: result.truncated === true,
            meta: result.meta
          };
        });
      })
      .catch(() => {
        if (cancelled || !live.current || latestRequest.current !== requestId) return;
        setState((previous) => {
          if (previous.identity !== identity || previous.phase === "ready") return previous;
          return {
            identity,
            phase: "failed",
            sourceGeneration: previous.sourceGeneration,
            truncated: false
          };
        });
      });
    return () => {
      cancelled = true;
    };
  }, [identity, key.agentId, key.taskId, key.workflowRunId, manual, open, tick]);

  const reload = useCallback(() => setManual((value) => value + 1), []);
  const visible =
    state.identity === identity
      ? state
      : loadingState(identity, state.sourceGeneration + 1);
  return { ...visible, reload };
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

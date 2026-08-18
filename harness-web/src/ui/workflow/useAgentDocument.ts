import { useCallback, useEffect, useRef, useState } from "react";
import { getBridge } from "../../bridge";
import { replayLines } from "../../model/transcript";
import { agentDocumentOf, type AgentDocument } from "./agentDocument";

export type DocumentPhase = "idle" | "loading" | "ready" | "missing" | "failed";

export interface DocumentState extends AgentDocument {
  phase: DocumentPhase;
  truncated: boolean;
}

const IDLE: DocumentState = { phase: "idle", truncated: false };

/**
 * The full prompt and outcome for one workflow agent, read from its own file on
 * disk — `harness.loadSubagentTranscript {workflowRunId, agentId}`.
 *
 * Deliberately lazy: the browser shows `promptPreview` / `resultPreview` off the
 * wire, and only the reader asking to expand one of them costs a bridge call.
 * One fetch serves BOTH sections, since both come out of the same file.
 *
 * `tick` is the reducer's per-task progress counter. A running agent's file
 * keeps growing, so an expanded outcome re-reads on it; a settled agent passes
 * `undefined` and is read exactly once.
 */
export function useAgentDocument(
  target: { workflowRunId?: string; agentId?: string },
  wanted: boolean,
  tick: number | undefined
): DocumentState & { reload(): void } {
  const [state, setState] = useState<DocumentState>(IDLE);
  const [manual, setManual] = useState(0);
  const live = useRef(true);
  const { workflowRunId, agentId } = target;

  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);

  // A different agent is a different document; without this the previous
  // agent's prompt would sit under the new agent's heading until its own fetch
  // resolved.
  useEffect(() => {
    setState(IDLE);
  }, [workflowRunId, agentId]);

  useEffect(() => {
    if (!wanted) return;
    if (!workflowRunId || !agentId) {
      setState({ phase: "missing", truncated: false });
      return;
    }
    let cancelled = false;
    // Not a reset to `loading`: a re-read on a progress tick would blank text
    // the reader is part-way through several times a minute.
    setState((previous) => (previous.phase === "idle" ? { ...previous, phase: "loading" } : previous));
    getBridge()
      .loadSubagentTranscript({ workflowRunId, agentId })
      .then((result) => {
        if (cancelled || !live.current) return;
        if (result.missing) {
          setState({ phase: "missing", truncated: false });
          return;
        }
        const document = agentDocumentOf(replayLines(result.events ?? []));
        setState({ ...document, phase: "ready", truncated: result.truncated === true });
      })
      .catch(() => {
        if (cancelled || !live.current) return;
        setState((previous) =>
          // A failed REFRESH must not throw away text that already rendered;
          // only a failed first read has nothing better to show.
          previous.phase === "ready" ? previous : { phase: "failed", truncated: false }
        );
      });
    return () => {
      cancelled = true;
    };
  }, [agentId, manual, tick, wanted, workflowRunId]);

  const reload = useCallback(() => setManual((value) => value + 1), []);
  return { ...state, reload };
}

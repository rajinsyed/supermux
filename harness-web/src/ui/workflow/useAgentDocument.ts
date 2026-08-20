import { useMemo } from "react";
import { agentDocumentOf, type AgentDocument } from "./agentDocument";
import { useSubagentTranscriptResource } from "../subagentTranscriptResource";

export type DocumentPhase = "idle" | "loading" | "ready" | "missing" | "failed";

export interface DocumentState extends AgentDocument {
  phase: DocumentPhase;
  truncated: boolean;
}

const IDLE: DocumentState = { phase: "idle", truncated: false };

/**
 * The full prompt and outcome for one workflow agent, derived from the same
 * shared transcript reducer that powers its inline disk transcript.
 */
export function useAgentDocument(
  target: { workflowRunId?: string; agentId?: string },
  wanted: boolean,
  tick: number | undefined
): DocumentState & { reload(): void } {
  const resource = useSubagentTranscriptResource(target, wanted, tick);
  const document = useMemo(
    () => (resource.model ? agentDocumentOf(resource.model) : {}),
    [resource.model]
  );

  if (!wanted) return { ...IDLE, reload: resource.reload };
  if (resource.phase === "ready") {
    return {
      ...document,
      phase: "ready",
      truncated: resource.truncated,
      reload: resource.reload
    };
  }
  return {
    phase: resource.phase,
    truncated: resource.truncated,
    reload: resource.reload
  };
}

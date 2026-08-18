import { replayLines } from "../../model/transcript";
import type { TranscriptModel } from "../../model/types";
import type { ProtocolLine } from "../../protocol/types";

/**
 * The two long strings a workflow agent's on-disk transcript holds that the
 * `workflow_progress` frames only preview: the prompt it was given and the
 * answer it produced.
 *
 * ROUND4 §"Workflow agent detail sources": the first user row of
 * `subagents/workflows/<runId>/agent-<agentId>.jsonl` is the FULL prompt, and
 * the last assistant text is the FULL outcome. The progress frames carry
 * `promptPreview` and `resultPreview`, which are truncated — expanding either
 * section is this read.
 */
export interface AgentDocument {
  prompt?: string;
  outcome?: string;
}

/** Pull the prompt and outcome out of a replayed agent transcript. */
export function agentDocumentOf(model: TranscriptModel): AgentDocument {
  let prompt: string | undefined;
  let outcome: string | undefined;
  for (const turn of model.turns) {
    // The agent's own prompt is the FIRST user row; later user rows are tool
    // results and mailbox messages, not the brief.
    if (prompt === undefined && turn.userText) prompt = turn.userText;
    for (const block of turn.blocks) {
      // The LAST text block wins: an agent that narrates before answering
      // leaves several, and the answer is the one at the end.
      if (block.kind === "text" && block.text.trim().length > 0) outcome = block.text;
    }
  }
  return { prompt, outcome };
}

export function agentDocumentFromLines(lines: ProtocolLine[]): AgentDocument {
  return agentDocumentOf(replayLines(lines));
}

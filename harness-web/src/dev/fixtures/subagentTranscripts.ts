import type { ProtocolLine } from "../../protocol/types";
import { assistantText, assistantToolUse, toolResult, userLine } from "./build";

/**
 * What `harness.loadSubagentTranscript` answers: the agent's own session-file
 * records, already mapped into the protocol shapes the reducer eats, exactly as
 * the native reader will return them.
 *
 * These are hand-built rather than probed because the probes could not capture
 * them: the agent transcripts live on disk under the session directory, not on
 * the wire. The SHAPES are the wire's, though — an agent file is a sequence of
 * user/assistant records with tool_use and tool_result blocks, which is what the
 * main session replays from history today.
 */
function agentTranscript(
  messageId: string,
  prompt: string,
  work: ProtocolLine[],
  answer: string
): ProtocolLine[] {
  return [userLine(prompt), ...work, assistantText(messageId, answer)];
}

/** The outer agent of the nested probe: it delegates, then reports the answer. */
export const nestedOuterTranscript: ProtocolLine[] = agentTranscript(
  "msg_drill_outer",
  "Use the Task tool to launch a nested general-purpose subagent whose prompt is 'Compute 17*3 and reply with just the number.' Wait for its answer and reply with exactly what it said.",
  [
    assistantText(
      "msg_drill_outer",
      "I'll delegate the arithmetic to a nested agent and pass its answer straight back."
    ),
    assistantToolUse("msg_drill_outer", "toolu_016ZUDvuwcLJADkKKzais8k2", "Agent", {
      description: "Compute 17*3",
      prompt: "Compute 17*3 and reply with just the number.",
      run_in_background: false
    }),
    toolResult("toolu_016ZUDvuwcLJADkKKzais8k2", "51", {
      status: "completed",
      agentId: "a9728442495aacb2c",
      agentType: "general-purpose",
      resolvedModel: "claude-sonnet-5",
      content: [{ type: "text", text: "51" }],
      totalDurationMs: 1646,
      totalTokens: 16802,
      totalToolUseCount: 0
    })
  ],
  "51"
);

/** The inner agent: no tools at all, which is a real and common shape. */
export const nestedInnerTranscript: ProtocolLine[] = agentTranscript(
  "msg_drill_inner",
  "Compute 17*3 and reply with just the number.",
  [],
  "51"
);

function workflowAgentTranscript(word: string, id: string): ProtocolLine[] {
  return agentTranscript(
    `msg_wf_${id}`,
    `Return exactly the word '${word}' and nothing else.`,
    [],
    word
  );
}

/** The merger did read both inputs, so its transcript has a tool call in it. */
export const workflowMergerTranscript: ProtocolLine[] = agentTranscript(
  "msg_wf_merger",
  'Combine these two words into a short result, return both: "alpha" and "beta"',
  [
    assistantToolUse("msg_wf_merger", "toolu_wf_merger_bash", "Bash", {
      command: "echo alphabeta",
      description: "Sanity-check the concatenation"
    }),
    toolResult("toolu_wf_merger_bash", "alphabeta", {
      stdout: "alphabeta",
      stderr: "",
      interrupted: false
    })
  ],
  "alphabeta, betaalpha"
);

/**
 * Keyed exactly as the bridge addresses them: a `local_agent` by task id, a
 * workflow agent by `runId/agentId`.
 */
export const round3SubagentTranscripts: Record<string, ProtocolLine[]> = {
  a273351272d38e227: nestedOuterTranscript,
  a9728442495aacb2c: nestedInnerTranscript,
  "wf_c0f60243-4f1/aec2c2f1b40b1481e": workflowAgentTranscript("alpha", "alpha"),
  "wf_c0f60243-4f1/a8ae08309fd862497": workflowAgentTranscript("beta", "beta"),
  "wf_c0f60243-4f1/a3591a4cc25d2d4ab": workflowMergerTranscript
};

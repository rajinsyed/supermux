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

/**
 * The FULL prompt and the FULL outcome, both longer than the previews the wire
 * sends.
 *
 * `promptPreview` and `resultPreview` on a `workflow_agent` item are
 * truncations, and the browser's Prompt/Outcome sections expand them by reading
 * the agent's own file. A fixture whose disk text equals its preview makes that
 * expansion invisible — the section swaps one string for the identical string —
 * so the one affordance the scenario exists to demonstrate could not be seen to
 * work. The first line of each still MATCHES the preview, because that is what
 * a truncation looks like.
 */
function workflowAgentTranscript(word: string, id: string): ProtocolLine[] {
  return agentTranscript(
    `msg_wf_${id}`,
    `Return exactly the word '${word}' and nothing else.\n\n` +
      "Do not explain, do not add punctuation, and do not wrap it in quotes. " +
      "The orchestrating workflow concatenates your answer with the other " +
      "gather agent's, so anything beyond the bare word ends up in the merged " +
      "result verbatim.",
    [],
    `${word}\n\n(Returned the bare word as instructed — no tools were needed for this step.)`
  );
}

/** The merger did read both inputs, so its transcript has a tool call in it. */
export const workflowMergerTranscript: ProtocolLine[] = agentTranscript(
  "msg_wf_merger",
  'Combine these two words into a short result, return both: "alpha" and "beta"\n\n' +
    "Return the forward concatenation first and the reverse second, separated " +
    "by a comma and a space. Neither gather agent knows about the other, so you " +
    "are the only step that sees both halves.",
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
  "alphabeta, betaalpha\n\n" +
    "Both orderings verified against the shell: the forward concatenation is " +
    "alphabeta and the reverse is betaalpha."
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

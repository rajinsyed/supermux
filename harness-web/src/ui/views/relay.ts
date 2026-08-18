/**
 * Messaging a running subagent.
 *
 * There is no control_request subtype that prompts an agent (the full dispatch
 * list was checked), and an outbound user frame carrying `parent_tool_use_id` is
 * IGNORED as targeting — it lands in main's queue. The CLI's own mechanism is
 * the agent mailbox, delivered at the agent's next tool round, and the way to
 * reach it over the wire is to ask MAIN to pass the message on with SendMessage.
 *
 * This exact wording is PROBED working (relay.jsonl): main replied RELAYED, ran
 * ListAgents + SendMessage, and the background agent quoted the guidance in its
 * final answer — the delivery also appearing in the agent's own thread as a
 * user-side message, which is what confirms the optimistic bubble here.
 */
export function relayInstruction(description: string, text: string): string {
  return (
    `Relay this message verbatim to the running '${description}' subagent using the ` +
    `SendMessage tool (use ListAgents to find it): '${text}'. ` +
    `Do not act on it yourself; reply only RELAYED.`
  );
}

/**
 * Main's acknowledgment of a relay, which the transcript compacts rather than
 * showing as an answer to the user. Matched loosely — the model has been seen
 * to answer "RELAYED." and "RELAYED" — but anchored, so an ordinary turn that
 * merely mentions the word is not swallowed.
 */
export function isRelayAck(text: string | undefined): boolean {
  if (!text) return false;
  return /^\s*relayed[.!]?\s*$/i.test(text);
}

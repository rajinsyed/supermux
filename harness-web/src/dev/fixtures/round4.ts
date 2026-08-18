import type { ProtocolLine } from "../../protocol/types";
import { initializeResponse } from "./build";
import { parseJsonl } from "./parse";
import { fwd2Round4Raw } from "./round4Fwd2Raw";
import { relayRound4Raw } from "./round4RelayRaw";

/**
 * The round-4 probes, verbatim off the wire (claude CLI 2.1.233), recorded with
 * `forwardSubagentText: true` in the initialize request.
 *
 * That flag is the whole round: without it only tool_use/tool_result frames
 * carry `parent_tool_use_id`, so a subagent's own words never reach the pane
 * and an agent view would have nothing to render. With it the FULL nested
 * conversation is live on the wire, which is what the agent threads are built
 * from.
 */
function probe(raw: string): ProtocolLine[] {
  return [initializeResponse(), ...parseJsonl(raw)];
}

/**
 * Nested agents with their conversations forwarded.
 *
 * Outer agent `toolu_014M6…` spawns inner `toolu_016qo…`; the inner Agent
 * `tool_use` block arrives on a frame whose parent is the OUTER id, and the
 * inner agent's own frames then carry its own — which is the round-4 attribution
 * rule the thread tree is built on.
 */
export const fwdNestedFixture: ProtocolLine[] = probe(fwd2Round4Raw);

/**
 * A message relayed to a running background agent.
 *
 * Turn 1 launches a backgrounded 'Slow summarizer'. Turn 2 is the relay: main
 * runs ListAgents + SendMessage and answers RELAYED, and the guidance then
 * appears in the agent's own final answer — the mailbox delivery landing at its
 * next tool round.
 */
export const relayFixture: ProtocolLine[] = probe(relayRound4Raw);

/** The outer and inner agents of `fwdNestedFixture`, by tool_use id. */
export const FWD_OUTER_TOOL_USE_ID = "toolu_014M6hCDrkbP2ab3e1Ggpnqy";
export const FWD_INNER_TOOL_USE_ID = "toolu_016qoBf5U7Ek1FjUwQcBf2dS";

/** The backgrounded agent the relay probe messages. */
export const RELAY_AGENT_TOOL_USE_ID = "toolu_01BHG8HPrqxd1XemAZsfvPrz";

export const ROUND4_CUTS = {
  /**
   * Through the inner agent's first forwarded frame: BOTH agents are live, the
   * outer one has already spoken, and the inner one has its prompt and nothing
   * else. That is the state the dock and the agent views exist for — a tree
   * mid-flight, not a finished transcript of one.
   */
  nested: 40,
  /**
   * Through the launching turn's `result`. The agent is backgrounded and still
   * running, which is the only state in which the relay path is reachable: the
   * composer in its view has an agent to message.
   */
  relay: 34
} as const;

import type { ProtocolLine } from "../../protocol/types";
import {
  assistantText,
  blockStart,
  blockStop,
  initLine,
  initializeResponse,
  messageStart,
  resultLine,
  sessionState,
  statusLine,
  streamThinking,
  streamToolUse,
  textDelta,
  toolResult,
  userLine
} from "./build";

const MSG = "msg_interrupt_0001";
const BASH_ID = "toolu_interrupt-bash-1";

const PARTIAL = `I'll walk the whole dependency graph first so the refactor lands in one pass rather than a series of half-migrations. Starting with the workspace packages, then the app target, then the`;

export const interruptFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine(),
  userLine("Refactor every call site of the old logging API across the repo."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG),
  ...streamThinking(MSG, 0, "This touches a lot of files. I'll survey first.", 96),
  ...streamToolUse(MSG, 1, BASH_ID, "Bash", {
    command: "rg -l 'LegacyLogger' --type swift | wc -l",
    description: "Count call sites"
  }),
  toolResult(BASH_ID, "217", { stdout: "217", stderr: "", interrupted: false }),
  blockStart(2, { type: "text", text: "" }),
  textDelta(2, PARTIAL.slice(0, 90)),
  textDelta(2, PARTIAL.slice(90)),
  {
    type: "assistant",
    message: {
      id: MSG,
      model: "claude-sonnet-5",
      type: "message",
      role: "assistant",
      content: [{ type: "text", text: PARTIAL }],
      usage: { input_tokens: 6, output_tokens: 210 }
    },
    parent_tool_use_id: null,
    session_id: "fixture-session-0001",
    uuid: "asst-interrupt-partial",
    aborted: true,
    timestamp: new Date().toISOString()
  } as ProtocolLine,
  blockStop(2),
  {
    type: "system",
    subtype: "informational",
    content: "Interrupted by user",
    level: "warning",
    uuid: "info-interrupt"
  } as ProtocolLine,
  sessionState("idle"),
  statusLine(null),
  resultLine({
    subtype: "error_during_execution",
    is_error: true,
    result: "Interrupted by user",
    terminal_reason: "aborted_streaming",
    duration_ms: 6210,
    num_turns: 2,
    total_cost_usd: 0.0217
  }),
  userLine("Never mind — just list the packages that reference it."),
  sessionState("running"),
  messageStart("msg_interrupt_0002"),
  assistantText(
    "msg_interrupt_0002",
    "Three packages reference `LegacyLogger`: `CmuxFoundation` (41 call sites), `CmuxWorkspaces` (12), and the app target (164)."
  ),
  sessionState("idle"),
  resultLine({
    result: "Three packages reference LegacyLogger.",
    num_turns: 1,
    total_cost_usd: 0.0339
  })
];

import type { ProtocolLine } from "../../protocol/types";
import {
  initLine,
  initializeResponse,
  messageStart,
  resultLine,
  sessionState,
  statusLine,
  streamText,
  streamToolUse,
  toolResult,
  uid,
  userLine
} from "./build";

const MSG_A = "msg_errors_0001";
const MSG_B = "msg_errors_0002";
const BASH_ID = "toolu_errors-bash-1";
const READ_ID = "toolu_errors-read-1";

const BUILD_FAILURE = `[1m[31merror[0m: cannot find 'HarnessPanel' in scope
  [34m-->[0m Sources/Panels/PanelContentView.swift:152:18
   [34m|[0m
152[34m |[0m         case .harness(let panel):
   [34m|[0m              [31m^~~~~~~~[0m
   [34m|[0m
   = note: did you mean 'agentSession'?

** BUILD FAILED **
The following build commands failed:
	SwiftCompile normal arm64 Compiling PanelContentView.swift
(1 failure)`;

export const errorsFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine(),
  userLine("Build the app and fix whatever breaks."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG_A),
  ...streamToolUse(MSG_A, 0, BASH_ID, "Bash", {
    command: "xcodebuild -scheme cmux -configuration Debug build",
    description: "Build the app"
  }),
  toolResult(BASH_ID, BUILD_FAILURE, {
    stdout: "",
    stderr: BUILD_FAILURE,
    interrupted: false,
    exitCode: 65
  }, true),
  {
    type: "system",
    subtype: "api_retry",
    attempt: 1,
    max_retries: 3,
    retry_delay_ms: 2400,
    error: "Overloaded — upstream returned 529",
    uuid: uid("retry")
  } as ProtocolLine,
  ...streamToolUse(MSG_A, 1, READ_ID, "Read", {
    file_path: "/Users/dev/projects/supermux/Sources/Panels/NoSuchFile.swift"
  }),
  toolResult(
    READ_ID,
    "Error: ENOENT: no such file or directory, open '/Users/dev/projects/supermux/Sources/Panels/NoSuchFile.swift'",
    undefined,
    true
  ),
  ...streamText(
    MSG_A,
    2,
    "The build fails because `PanelContentView` references a `.harness` case that the `PanelType` enum never gained. I'll add the case."
  ),
  statusLine(null),
  resultLine({
    subtype: "error_during_execution",
    is_error: true,
    result: "Build failed: cannot find 'HarnessPanel' in scope (PanelContentView.swift:152).",
    terminal_reason: "error",
    num_turns: 2,
    total_cost_usd: 0.0421
  }),
  userLine("Try again."),
  sessionState("running"),
  messageStart(MSG_B),
  {
    type: "assistant",
    message: {
      id: MSG_B,
      model: "claude-sonnet-5",
      type: "message",
      role: "assistant",
      content: [{ type: "text", text: "" }],
      usage: {}
    },
    error: {
      type: "rate_limit",
      message:
        "You have reached your usage limit for Claude Opus. Limits reset at 4:00 PM. Switch to Sonnet to keep working."
    },
    parent_tool_use_id: null,
    session_id: "fixture-session-0001",
    uuid: uid("asst-err"),
    timestamp: new Date().toISOString()
  } as ProtocolLine,
  resultLine({
    subtype: "error_during_execution",
    is_error: true,
    result: "Usage limit reached.",
    terminal_reason: "error",
    num_turns: 0,
    total_cost_usd: 0.0421
  })
];

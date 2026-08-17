import type { ProtocolLine } from "../../protocol/types";
import {
  assistantText,
  assistantToolUse,
  initLine,
  initializeResponse,
  messageStart,
  resultLine,
  sessionState,
  statusLine,
  toolResult,
  userLine
} from "./build";

const MSG_A = "msg_resume_history_1";
const MSG_B = "msg_resume_history_2";

export const resumeHistory: ProtocolLine[] = [
  // Resuming still spawns a process, and the harness always performs the
  // `initialize` handshake on start — so the model catalog is present here just
  // as it is on a fresh session. Without it the header has no catalog to resolve
  // init's resolved model id against and the pill prints the raw id.
  initializeResponse(),
  initLine({ session_id: "resumed-session-4821" }),
  userLine("Why does the sidebar lose its scroll position when a workspace is restored?"),
  messageStart(MSG_A),
  assistantToolUse(MSG_A, "toolu_resume-read-1", "Read", {
    file_path: "/Users/dev/projects/supermux/Sources/SessionIndexView.swift"
  }),
  toolResult("toolu_resume-read-1", "     1\timport SwiftUI", {
    type: "text",
    file: {
      filePath: "/Users/dev/projects/supermux/Sources/SessionIndexView.swift",
      content: "import SwiftUI\n",
      numLines: 612,
      startLine: 1,
      totalLines: 612
    }
  }),
  assistantText(
    MSG_A,
    "Restore rebuilds the list identity: the `ForEach` is keyed on the panel object rather than a stable id, so SwiftUI treats every row as new and resets the scroll offset."
  ),
  resultLine({
    result: "The ForEach identity changes on restore, resetting scroll offset.",
    num_turns: 2,
    total_cost_usd: 0.0412
  }),
  userLine("Fix it."),
  messageStart(MSG_B),
  assistantToolUse(MSG_B, "toolu_resume-edit-1", "Edit", {
    file_path: "/Users/dev/projects/supermux/Sources/SessionIndexView.swift",
    old_string: "ForEach(panels, id: \\.self)",
    new_string: "ForEach(panels, id: \\.stableID)"
  }),
  toolResult("toolu_resume-edit-1", "Edited.", {
    filePath: "/Users/dev/projects/supermux/Sources/SessionIndexView.swift",
    userModified: false,
    structuredPatch: [
      {
        oldStart: 188,
        oldLines: 4,
        newStart: 188,
        newLines: 4,
        lines: [
          "     LazyVStack(spacing: 0) {",
          "-        ForEach(panels, id: \\.self) { panel in",
          "+        ForEach(panels, id: \\.stableID) { panel in",
          "             SessionRow(snapshot: panel.snapshot)"
        ]
      }
    ]
  }),
  assistantText(
    MSG_B,
    "Keyed the `ForEach` on `stableID`, which survives restore. Scroll position now persists across a workspace reload."
  ),
  resultLine({
    result: "Keyed the ForEach on stableID; scroll position survives restore.",
    num_turns: 2,
    total_cost_usd: 0.0863
  })
];

export const resumeFixture: ProtocolLine[] = [
  ...resumeHistory,
  initLine({ session_id: "resumed-session-4821" }),
  userLine("Add a regression test for that."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart("msg_resume_live"),
  assistantText(
    "msg_resume_live",
    "Adding `SessionIndexScrollRestoreTests` that snapshots the offset, triggers a restore, and asserts the offset is unchanged."
  ),
  sessionState("idle"),
  statusLine(null),
  resultLine({ result: "Added SessionIndexScrollRestoreTests." })
];

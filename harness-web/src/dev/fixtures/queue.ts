import type { ProtocolLine } from "../../protocol/types";
import {
  initLine,
  initializeResponse,
  messageStart,
  sessionState,
  statusLine,
  streamThinking,
  streamToolUse,
  userLine
} from "./build";

const MSG = "msg_queue_0001";

export const queueFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine(),
  userLine("Audit the workspace snapshot code for restore bugs."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG),
  ...streamThinking(
    MSG,
    0,
    "Snapshot and restore are two separate switches, so drift between them is the usual failure. I'll read both arms and compare field by field.",
    268
  ),
  ...streamToolUse(MSG, 1, "toolu_queue-grep-1", "Grep", {
    pattern: "Snapshot",
    path: "Sources/Workspace.swift",
    output_mode: "content",
    "-n": true
  })
];

export const queuedDrafts: string[] = [
  "Also check the iOS side — SessionPersistence has its own decode path.",
  "And add a round-trip test once you find the drift."
];

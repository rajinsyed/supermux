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

const MSG_A = "msg_compact_0001";
const MSG_B = "msg_compact_0002";

export const compactFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine(),
  userLine("Summarize what we changed in the renderer this session."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG_A),
  ...streamText(
    MSG_A,
    0,
    "We replaced the per-frame display link with Ghostty's own wakeup path, removed the manual `ghostty_surface_draw` loop, and moved the search overlay into the portal layer."
  ),
  sessionState("idle"),
  resultLine({ result: "Summarized renderer changes.", num_turns: 1, total_cost_usd: 0.0611 }),
  userLine("/compact focus on the renderer decisions"),
  statusLine("compacting"),
  {
    type: "system",
    subtype: "compact_boundary",
    compact_metadata: { trigger: "manual", pre_tokens: 148320 },
    uuid: uid("compact")
  } as ProtocolLine,
  statusLine(null, { compact_result: "success" }),
  initLine({ uuid: uid("init") }),
  userLine("Now add a regression test for the wakeup path."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG_B),
  ...streamToolUse(MSG_B, 0, "toolu_compact-write-1", "Write", {
    file_path: "/Users/dev/projects/supermux/cmuxTests/RendererWakeupTests.swift",
    content:
      'import Testing\n@testable import cmux\n\n@Suite(.serialized)\nstruct RendererWakeupTests {\n    @Test func doesNotInstallDisplayLink() {\n        let renderer = TerminalRenderer(surface: .stub)\n        #expect(renderer.displayLink == nil)\n    }\n}\n'
  }),
  toolResult("toolu_compact-write-1", "File created successfully.", {
    type: "create",
    filePath: "/Users/dev/projects/supermux/cmuxTests/RendererWakeupTests.swift",
    content:
      'import Testing\n@testable import cmux\n\n@Suite(.serialized)\nstruct RendererWakeupTests {\n    @Test func doesNotInstallDisplayLink() {\n        let renderer = TerminalRenderer(surface: .stub)\n        #expect(renderer.displayLink == nil)\n    }\n}\n',
    structuredPatch: []
  }),
  ...streamText(
    MSG_B,
    1,
    "Added `RendererWakeupTests` asserting no display link is installed. Remember it needs pbxproj wiring or it silently never runs."
  ),
  sessionState("idle"),
  statusLine(null),
  resultLine({
    result: "Added RendererWakeupTests.",
    num_turns: 1,
    total_cost_usd: 0.0788
  })
];

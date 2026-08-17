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

const FILES = [
  "Sources/Workspace.swift",
  "Sources/Panels/Panel.swift",
  "Sources/Panels/PanelContentView.swift",
  "Sources/ContentView.swift",
  "Sources/AppDelegate.swift",
  "Packages/macOS/CmuxWorkspaces/Sources/CmuxWorkspaces/Core/Values/SurfaceKind.swift",
  "Packages/SupermuxKit/Sources/SupermuxKit/ClaudeHarness/HarnessProtocol.swift"
];

function buildLongSession(): ProtocolLine[] {
  const lines: ProtocolLine[] = [initializeResponse(), initLine()];
  for (let turn = 0; turn < 24; turn += 1) {
    const messageId = `msg_long_${turn}`;
    lines.push(userLine(`Pass ${turn + 1}: audit ${FILES[turn % FILES.length]} and report findings.`));
    lines.push(sessionState("running"));
    lines.push(statusLine("requesting"));
    lines.push(messageStart(messageId));
    lines.push(
      assistantText(
        messageId,
        `Reading \`${FILES[turn % FILES.length]}\` and cross-checking the switch arms against the enum definition.`
      )
    );
    for (let step = 0; step < 15; step += 1) {
      const toolId = `toolu_long_${turn}_${step}`;
      const isBash = step % 3 === 0;
      if (isBash) {
        lines.push(
          assistantToolUse(messageId, toolId, "Bash", {
            command: `rg -n "case " ${FILES[(turn + step) % FILES.length]} | head -20`,
            description: "List enum arms"
          })
        );
        lines.push(
          toolResult(
            toolId,
            Array.from({ length: 14 }, (_, i) => `${i + 12}:    case option${i}`).join("\n"),
            { stdout: "ok", stderr: "", interrupted: false }
          )
        );
      } else if (step % 3 === 1) {
        lines.push(
          assistantToolUse(messageId, toolId, "Read", {
            file_path: `/Users/dev/projects/supermux/${FILES[(turn + step) % FILES.length]}`
          })
        );
        lines.push(
          toolResult(toolId, "     1\timport SwiftUI\n     2\t", {
            type: "text",
            file: {
              filePath: FILES[(turn + step) % FILES.length],
              content: "import SwiftUI\n",
              numLines: 480 + step,
              startLine: 1,
              totalLines: 480 + step
            }
          })
        );
      } else {
        lines.push(
          assistantToolUse(messageId, toolId, "Edit", {
            file_path: `/Users/dev/projects/supermux/${FILES[(turn + step) % FILES.length]}`,
            old_string: `case option${step}`,
            new_string: `case option${step}Renamed`
          })
        );
        lines.push(
          toolResult(toolId, "Edited.", {
            filePath: FILES[(turn + step) % FILES.length],
            userModified: false,
            structuredPatch: [
              {
                oldStart: 20 + step,
                oldLines: 3,
                newStart: 20 + step,
                newLines: 3,
                lines: [
                  "     case alpha",
                  `-    case option${step}`,
                  `+    case option${step}Renamed`
                ]
              }
            ]
          })
        );
      }
    }
    lines.push(
      assistantText(
        messageId,
        `Pass ${turn + 1} complete. Found ${(turn % 4) + 1} drift sites; the risky ones use \`default:\` and swallow new cases.`
      )
    );
    lines.push(statusLine(null));
    lines.push(
      resultLine({
        result: `Pass ${turn + 1} complete.`,
        num_turns: 6,
        total_cost_usd: 0.032 * (turn + 1),
        duration_ms: 12000 + turn * 900
      })
    );
  }
  return lines;
}

export const longformFixture: ProtocolLine[] = buildLongSession();

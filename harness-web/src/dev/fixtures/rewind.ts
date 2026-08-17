import type { ProtocolLine } from "../../protocol/types";
import {
  assistantText,
  assistantToolUse,
  initLine,
  initializeResponse,
  messageStart,
  resultLine,
  toolResult,
  userLine
} from "./build";

const SESSION = "rewind-session-7712";

/**
 * Four user messages with STABLE uuids, because a rewind is addressed by the
 * uuid of the message it targets: a fixture that regenerated them each load
 * could not be scripted against, and every hand-check would exercise a
 * different target. Message 3 edits a file, so its rewind has something real to
 * restore, and message 1 exists so the "no predecessor → fresh session" branch
 * is reachable.
 */
export const REWIND_UUIDS = {
  first: "rw-user-0001",
  second: "rw-user-0002",
  third: "rw-user-0003",
  fourth: "rw-user-0004"
} as const;

function stampedUser(text: string, uuid: string): ProtocolLine {
  return { ...(userLine(text) as Record<string, unknown>), uuid } as ProtocolLine;
}

const MSG_1 = "msg_rewind_1";
const MSG_2 = "msg_rewind_2";
const MSG_3 = "msg_rewind_3";
const MSG_4 = "msg_rewind_4";

export const rewindHistory: ProtocolLine[] = [
  initializeResponse(),
  initLine({ session_id: SESSION }),

  stampedUser("Where does the harness decide which session to resume?", REWIND_UUIDS.first),
  messageStart(MSG_1),
  assistantText(
    MSG_1,
    "`ensureStarted` in `useHarness.ts` picks the resume target. It reads the restore snapshot, which is the panel's serialized value rather than the session the pane is currently on."
  ),
  resultLine({ result: "Resume target comes from the restore snapshot.", num_turns: 1 }),

  stampedUser("Is that why picking a session from the browser fails?", REWIND_UUIDS.second),
  messageStart(MSG_2),
  assistantText(
    MSG_2,
    "Partly. The harder failure is that `start` refuses outright while a process is live — the controller throws `sessionAlreadyRunning`, and the web side never stops the old process first."
  ),
  resultLine({ result: "start() refuses while a process is live.", num_turns: 1 }),

  stampedUser("Rename the resume helper to resumeTarget and update its callers.", REWIND_UUIDS.third),
  messageStart(MSG_3),
  assistantToolUse(MSG_3, "toolu_rewind-edit-1", "Edit", {
    file_path: "/Users/dev/projects/supermux/harness-web/src/ui/useHarness.ts",
    old_string: "const currentSessionId =",
    new_string: "const resumeTarget ="
  }),
  toolResult("toolu_rewind-edit-1", "Edited.", {
    filePath: "/Users/dev/projects/supermux/harness-web/src/ui/useHarness.ts",
    userModified: false,
    structuredPatch: [
      {
        oldStart: 142,
        oldLines: 3,
        newStart: 142,
        newLines: 3,
        lines: [
          "   */",
          "-  const currentSessionId = useCallback(",
          "+  const resumeTarget = useCallback(",
          "     (): string | undefined =>"
        ]
      }
    ]
  }),
  assistantText(MSG_3, "Renamed it and updated both call sites."),
  resultLine({ result: "Renamed currentSessionId to resumeTarget.", num_turns: 2 }),

  stampedUser("Actually, revert that — the old name was clearer.", REWIND_UUIDS.fourth),
  messageStart(MSG_4),
  assistantText(
    MSG_4,
    "Reverted. `currentSessionId` says what the value IS; `resumeTarget` says what one caller does with it."
  ),
  resultLine({ result: "Reverted the rename.", num_turns: 1 })
];

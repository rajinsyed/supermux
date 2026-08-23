import type { ProtocolLine } from "../../protocol/types";
import {
  assistantToolUse,
  canUseTool,
  initLine,
  initializeResponse,
  messageStart,
  messageStop,
  resultLine,
  sessionState,
  statusLine,
  streamText,
  streamThinking,
  streamToolUse,
  toolResult,
  userLine
} from "./build";

const MSG = "msg_plan_0001";
const READ_ID = "toolu_plan-read-1";
const GREP_ID = "toolu_plan-grep-1";
const PLAN_ID = "toolu_req-plan-1";

const PLAN_MARKDOWN = `## Move terminal search into the portal layer

The find overlay currently mounts from \`TerminalPanelView\`, which sits below the portal-hosted
terminal during split churn — that is why the overlay disappears behind the surface.

### Steps

1. **Move the mount point.** Delete the \`SurfaceSearchOverlay\` instantiation in
   \`Sources/Panels/TerminalPanelView.swift:212\` and mount it from
   \`GhosttySurfaceScrollView\` in \`Sources/GhosttyTerminalView.swift\` instead, so it lives in the
   same AppKit layer as the surface it decorates.
2. **Route focus through the surface.** \`TerminalSurface.focusSearchField()\` becomes the single
   entrypoint; the shortcut, the menu item, and the palette command all call it.
3. **Keep the escape path.** Escape dismisses the overlay and returns first responder to the
   surface — verified against the split/unsplit churn repro in issue #2586.
4. **Regression test.** Add \`TerminalSearchOverlayLayeringTests\` asserting the overlay's
   superview is the scroll view, not the SwiftUI host.

### Risks

- \`hitTest()\` is on the typing-latency path. The overlay must not add work when it is hidden;
  guard on \`isHidden\` before any subview walk.
- Two entrypoints today duplicate the toggle logic. Collapsing them changes behavior for the
  menu item, so both need manual verification.

### Not doing

Rewriting the search backend, or changing the match-highlight renderer. Out of scope.`;

export const planFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine({ permissionMode: "plan" }),
  userLine("The terminal find overlay hides behind the surface after splitting a pane. Plan a fix."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG),
  ...streamThinking(
    MSG,
    0,
    "Layering problem. The overlay is mounted from SwiftUI while the terminal is portal-hosted in AppKit, so during split churn the portal view can end up above the SwiftUI content. I should read the two mount sites before proposing anything.",
    418
  ),
  ...streamToolUse(MSG, 1, READ_ID, "Read", {
    file_path: "/Users/dev/projects/supermux/Sources/Panels/TerminalPanelView.swift"
  }),
  messageStop(),
  toolResult(READ_ID, "     1\timport SwiftUI\n     2\timport CmuxFoundation\n…", {
    type: "text",
    file: {
      filePath: "/Users/dev/projects/supermux/Sources/Panels/TerminalPanelView.swift",
      content: "import SwiftUI\n",
      numLines: 284,
      startLine: 1,
      totalLines: 284
    }
  }),
  ...streamToolUse(MSG, 2, GREP_ID, "Grep", {
    pattern: "SurfaceSearchOverlay",
    path: "Sources",
    output_mode: "files_with_matches"
  }),
  toolResult(GREP_ID, "Found 3 files", {
    mode: "files_with_matches",
    numFiles: 3,
    filenames: [
      "Sources/Panels/TerminalPanelView.swift",
      "Sources/GhosttyTerminalView.swift",
      "Sources/Search/SurfaceSearchOverlay.swift"
    ],
    durationMs: 61
  }),
  assistantToolUse(MSG, PLAN_ID, "ExitPlanMode", { plan: PLAN_MARKDOWN }),
  sessionState("requires_action"),
  canUseTool("req-plan-1", "ExitPlanMode", { plan: PLAN_MARKDOWN }, {
    title: "Ready to code?",
    tool_use_id: PLAN_ID
  })
];

export const planApproval: ProtocolLine[] = [
  toolResult(PLAN_ID, "User approved the plan."),
  sessionState("running"),
  ...streamText(
    MSG,
    3,
    "Approved — switching to acceptEdits and starting with the mount-point move in `TerminalPanelView.swift`."
  ),
  statusLine(null),
  resultLine({ result: "Plan approved; implementation started." })
];

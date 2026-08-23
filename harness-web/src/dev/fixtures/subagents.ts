import type { ProtocolLine } from "../../protocol/types";
import {
  assistantToolUse,
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
  uid,
  userLine
} from "./build";

const MSG = "msg_subagents_0001";
const TASK_A = "toolu_sub-task-a";
const TASK_B = "toolu_sub-task-b";
const SUB_MSG_A = "msg_sub_a";

function taskLine(
  subtype: string,
  taskId: string,
  toolUseId: string,
  extra: Record<string, unknown> = {}
): ProtocolLine {
  return { type: "system", subtype, task_id: taskId, tool_use_id: toolUseId, uuid: uid("task"), ...extra } as ProtocolLine;
}

export const subagentsFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine(),
  userLine("Map every place the panel type enum is switched on, and separately audit the localization catalog."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG),
  ...streamThinking(
    MSG,
    0,
    "Two independent searches. Running them as parallel subagents keeps the main context clean and halves the wall time.",
    204
  ),
  ...streamToolUse(MSG, 1, TASK_A, "Task", {
    description: "Map PanelType switch sites",
    subagent_type: "Explore",
    prompt: "Find every exhaustive switch over PanelType in Sources/ and report file:line plus the arm shape."
  }),
  assistantToolUse(MSG, TASK_B, "Task", {
    description: "Audit localization catalog",
    subagent_type: "general-purpose",
    prompt: "Check Resources/Localizable.xcstrings for supermux.* keys missing a ja translation."
  }),
  messageStop(),
  taskLine("task_started", "task_a1", TASK_A, {
    description: "Map PanelType switch sites",
    subagent_type: "Explore",
    task_type: "local_agent",
    prompt: "Find every exhaustive switch over PanelType"
  }),
  taskLine("task_started", "task_b1", TASK_B, {
    description: "Audit localization catalog",
    subagent_type: "general-purpose",
    task_type: "background"
  }),
  messageStart(SUB_MSG_A, TASK_A),
  ...streamToolUse(SUB_MSG_A, 0, "toolu_sub-grep-1", "Grep", {
    pattern: "switch panel",
    path: "Sources",
    output_mode: "content"
  }, TASK_A),
  toolResult(
    "toolu_sub-grep-1",
    "Sources/Panels/PanelContentView.swift:49\nSources/Canvas/WorkspaceCanvasHostView.swift:101\nSources/ContentView+SidebarSurfaceKind.swift:5",
    { mode: "content", numLines: 3, durationMs: 88 },
    false,
    TASK_A
  ),
  taskLine("task_progress", "task_a1", TASK_A, {
    description: "Running Grep for exhaustive switches",
    subagent_type: "Explore",
    last_tool_name: "Grep",
    usage: { total_tokens: 18420, tool_uses: 2, duration_ms: 3140 }
  }),
  {
    type: "user",
    message: {
      role: "user",
      content: [
        {
          type: "text",
          text: "Found 11 exhaustive switch sites. The riskiest are the two in Workspace.swift because they use `default:` and will silently swallow a new case."
        }
      ]
    },
    parent_tool_use_id: TASK_A,
    session_id: "fixture-session-0001",
    uuid: uid("subtext"),
    subagent_type: "Explore",
    task_description: "Map PanelType switch sites",
    timestamp: new Date().toISOString()
  } as ProtocolLine,
  taskLine("task_updated", "task_a1", TASK_A, { patch: { status: "completed", end_time: Date.now() } }),
  taskLine("task_notification", "task_a1", TASK_A, {
    status: "completed",
    summary: "11 exhaustive switch sites; 2 use `default:` and will swallow a new case silently.",
    output_file: "/tmp/claude/agents/task_a1.md",
    usage: { total_tokens: 21806, tool_uses: 4, duration_ms: 8412 }
  }),
  toolResult(TASK_A, "11 exhaustive switch sites over PanelType.", {
    status: "completed",
    agentId: "task_a1",
    agentType: "Explore",
    content: [{ type: "text", text: "11 exhaustive switch sites over PanelType." }],
    totalDurationMs: 8412,
    totalTokens: 21806,
    totalToolUseCount: 4,
    toolStats: {
      readCount: 2,
      searchCount: 2,
      bashCount: 0,
      editFileCount: 0,
      linesAdded: 0,
      linesRemoved: 0,
      otherToolCount: 0
    }
  }),
  {
    type: "system",
    subtype: "background_tasks_changed",
    tasks: [
      {
        task_id: "task_b1",
        description: "Audit localization catalog",
        status: "running",
        subagent_type: "general-purpose",
        usage: { total_tokens: 9120, tool_uses: 3, duration_ms: 5210 }
      }
    ],
    uuid: uid("bg")
  } as ProtocolLine,
  taskLine("task_progress", "task_b1", TASK_B, {
    description: "Reading Resources/Localizable.xcstrings",
    subagent_type: "general-purpose",
    last_tool_name: "Read",
    usage: { total_tokens: 9120, tool_uses: 3, duration_ms: 5210 }
  }),
  taskLine("task_notification", "task_b1", TASK_B, {
    status: "completed",
    summary: "6 supermux.* keys have en but no ja translation.",
    usage: { total_tokens: 12440, tool_uses: 5, duration_ms: 11200 }
  }),
  toolResult(TASK_B, "6 keys missing ja.", {
    status: "completed",
    agentId: "task_b1",
    agentType: "general-purpose",
    content: [{ type: "text", text: "6 supermux.* keys have en but no ja translation." }],
    totalDurationMs: 11200,
    totalTokens: 12440,
    totalToolUseCount: 5
  }),
  ...streamText(
    MSG,
    2,
    "Both audits are in.\n\n- **Switch sites:** 11 total. Two in `Workspace.swift` use `default:` and will silently swallow a new panel case — those need explicit arms.\n- **Localization:** 6 `supermux.*` keys have English but no Japanese; the merge script will fail the catalog check until they are filled in."
  ),
  statusLine(null),
  resultLine({
    result: "11 switch sites (2 unsafe), 6 localization keys missing ja.",
    num_turns: 4,
    total_cost_usd: 0.2614
  })
];

import type { JsonObject, ProtocolLine } from "../../protocol/types";
import {
  initLine,
  initializeResponse,
  messageStart,
  sessionState,
  statusLine,
  streamThinking,
  streamToolUse,
  toolResult,
  userLine
} from "./build";

const MSG = "msg_todos_0001";

const STEPS = [
  "Add the claudeHarness case to PanelType",
  "Render the panel in PanelContentView",
  "Wire the workspace factory and snapshot",
  "Add the command palette entry",
  "Register the keyboard shortcut",
  "Localize every new string",
  "Add snapshot round-trip tests"
];

function todos(doneCount: number, activeIndex: number): JsonObject[] {
  return STEPS.map((content, i) => ({
    content,
    status: i < doneCount ? "completed" : i === activeIndex ? "in_progress" : "pending",
    activeForm: content
  }));
}

export const todosFixture: ProtocolLine[] = [
  initializeResponse(),
  initLine({ permissionMode: "acceptEdits" }),
  userLine("Add the Claude harness pane end to end. Track your steps."),
  sessionState("running"),
  statusLine("requesting"),
  messageStart(MSG),
  ...streamThinking(MSG, 0, "Seven distinct steps. Worth tracking explicitly.", 88),
  ...streamToolUse(MSG, 1, "toolu_todo-1", "TodoWrite", { todos: todos(0, 0) }),
  toolResult("toolu_todo-1", "Todos updated", {
    oldTodos: [],
    newTodos: todos(0, 0)
  }),
  ...streamToolUse(MSG, 2, "toolu_todo-edit-1", "Edit", {
    file_path: "/Users/dev/projects/supermux/Sources/Panels/Panel.swift",
    old_string: "    case agentSession",
    new_string: "    case agentSession\n    case claudeHarness"
  }),
  toolResult("toolu_todo-edit-1", "Edited Panel.swift", {
    filePath: "/Users/dev/projects/supermux/Sources/Panels/Panel.swift",
    userModified: false,
    structuredPatch: [
      {
        oldStart: 12,
        oldLines: 4,
        newStart: 12,
        newLines: 5,
        lines: [
          "     case filePreview",
          "     case simulator",
          "     case agentSession",
          "+    case claudeHarness",
          " }"
        ]
      }
    ]
  }),
  ...streamToolUse(MSG, 3, "toolu_todo-2", "TodoWrite", { todos: todos(2, 2) }),
  toolResult("toolu_todo-2", "Todos updated", {
    oldTodos: todos(0, 0),
    newTodos: todos(2, 2)
  }),
  ...streamToolUse(MSG, 4, "toolu_todo-bash-1", "Bash", {
    command: "xcodebuild -scheme cmux -configuration Debug -derivedDataPath /tmp/cmux-harness build 2>&1 | tail -5",
    description: "Compile check"
  }),
  toolResult("toolu_todo-bash-1", "** BUILD SUCCEEDED **", {
    stdout: "** BUILD SUCCEEDED **",
    stderr: "",
    interrupted: false
  }),
  ...streamToolUse(MSG, 5, "toolu_todo-3", "TodoWrite", { todos: todos(3, 3) }),
  toolResult("toolu_todo-3", "Todos updated", {
    oldTodos: todos(2, 2),
    newTodos: todos(3, 3)
  })
];

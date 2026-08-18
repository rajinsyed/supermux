import type { JsonObject, TodoItem } from "../protocol/types";
import { asNumber, asString, isPlainObject } from "./helpers";
import type { ToolStatus } from "./types";

const FAILURE_PATTERNS = [
  /\bENOENT\b/,
  /\bEACCES\b/,
  /command not found/i,
  /No such file or directory/i,
  /exited with (?:exit )?code [1-9]/i,
  /Permission denied/i,
  /\berror:/i,
  /Traceback \(most recent call last\)/,
  /fatal:/i
];

export function sniffFailure(text: string | undefined): boolean {
  if (!text) return false;
  const head = text.slice(0, 4000);
  return FAILURE_PATTERNS.some((pattern) => pattern.test(head));
}

export function classifyToolStatus(
  toolName: string,
  isError: boolean,
  resultText: string | undefined,
  structured: JsonObject | undefined
): ToolStatus {
  if (structured?.interrupted === true) return "aborted";
  if (isError) return "error";
  if (structured) {
    const status = asString(structured.status);
    if (status === "failed" || status === "error") return "error";
    if (status === "killed" || status === "stopped" || status === "aborted") return "aborted";
    if (toolName === "Bash") {
      const stderr = asString(structured.stderr) ?? "";
      const code = asNumber(structured.exitCode ?? structured.exit_code);
      if (code !== undefined && code !== 0) return "error";
      if (stderr.length > 0 && sniffFailure(stderr)) return "error";
      return "success";
    }
    // Agent reports are natural-language audits and often contain literals such
    // as "error:" or "fatal:" while the AgentOutput status says the work
    // completed. A structured terminal/launch verdict is stronger than text
    // sniffing; otherwise a successful error investigation paints a red row.
    if (status === "completed" || status === "success" || status === "async_launched") {
      return "success";
    }
  }
  if (sniffFailure(resultText)) return "error";
  return "success";
}

export function extractTodos(
  toolName: string,
  input: JsonObject,
  structured: JsonObject | undefined
): TodoItem[] | undefined {
  if (toolName !== "TodoWrite") return undefined;
  const fromStructured = structured?.newTodos;
  if (Array.isArray(fromStructured)) return normalizeTodos(fromStructured);
  const fromInput = input.todos;
  if (Array.isArray(fromInput)) return normalizeTodos(fromInput);
  return undefined;
}

function normalizeTodos(list: unknown[]): TodoItem[] {
  const todos: TodoItem[] = [];
  for (const raw of list) {
    if (!isPlainObject(raw)) continue;
    const content = asString(raw.content) ?? asString(raw.task);
    if (!content) continue;
    todos.push({
      content,
      status: asString(raw.status) ?? "pending",
      activeForm: asString(raw.activeForm)
    });
  }
  return todos;
}

export function bashExitCode(structured: JsonObject | undefined): number | undefined {
  if (!structured) return undefined;
  return asNumber(structured.exitCode ?? structured.exit_code);
}

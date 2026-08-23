import type { JsonObject } from "../../protocol/types";
import type { CopyFn } from "../CopyContext";
import { basename, shortenPath, truncateMiddle } from "../format";

export type ToolFamily =
  | "workflow"
  | "bash"
  | "edit"
  | "write"
  | "read"
  | "search"
  | "web"
  | "todo"
  | "task"
  | "mcp"
  | "interactive"
  | "generic";

export const INTERACTIVE_TOOLS = new Set(["ExitPlanMode", "EnterPlanMode", "AskUserQuestion"]);

export function toolFamily(name: string): ToolFamily {
  if (INTERACTIVE_TOOLS.has(name)) return "interactive";
  if (name === "Bash" || name === "BashOutput" || name === "KillShell") return "bash";
  if (name === "Edit" || name === "MultiEdit" || name === "NotebookEdit") return "edit";
  if (name === "Write") return "write";
  if (name === "Read") return "read";
  if (name === "Grep" || name === "Glob" || name === "ToolSearch" || name === "LSP") return "search";
  if (name === "WebSearch" || name === "WebFetch") return "web";
  if (name === "TodoWrite") return "todo";
  if (name === "Task" || name === "Agent") return "task";
  // Its own family, not a subagent: a Workflow launches MANY agents across
  // phases and reports them through `workflow_progress`, which SubagentCard has
  // no place to put.
  if (name === "Workflow") return "workflow";
  if (name.startsWith("mcp__")) return "mcp";
  return "generic";
}

export function mcpServerName(name: string): string | undefined {
  if (!name.startsWith("mcp__")) return undefined;
  return name.split("__")[1];
}

export function mcpToolName(name: string): string {
  if (!name.startsWith("mcp__")) return name;
  const parts = name.split("__");
  return parts.slice(2).join("__") || name;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function toolHeadline(name: string, input: JsonObject, copy: CopyFn): string {
  const family = toolFamily(name);
  switch (family) {
    case "bash": {
      const command = str(input.command);
      return command ? truncateMiddle(command.split("\n")[0], 120) : name;
    }
    case "edit":
    case "write":
    case "read": {
      const path = str(input.file_path) ?? str(input.filePath) ?? str(input.notebook_path);
      return path ? basename(path) : name;
    }
    case "search": {
      const pattern = str(input.pattern) ?? str(input.query);
      return pattern ? truncateMiddle(pattern, 80) : name;
    }
    case "web": {
      const url = str(input.url);
      const query = str(input.query);
      return url ?? query ?? name;
    }
    case "task":
      return str(input.description) ?? name;
    case "workflow":
      return str(input.name) ?? str(input.scriptPath) ?? name;
    case "todo":
      return copy("supermux.harness.tool.headline.todo");
    case "interactive":
      if (name === "AskUserQuestion") {
        return copy("supermux.harness.tool.headline.askUser");
      }
      if (name === "EnterPlanMode") {
        return copy("supermux.harness.tool.headline.enterPlan");
      }
      return copy("supermux.harness.tool.headline.presentPlan");
    case "mcp":
      return mcpToolName(name);
    default: {
      const first = Object.values(input).find((v) => typeof v === "string") as string | undefined;
      return first ? truncateMiddle(first, 90) : name;
    }
  }
}

/** The unabbreviated subtitle, for the head's `title` tooltip. */
export function toolSubtitleFull(name: string, input: JsonObject): string | undefined {
  const family = toolFamily(name);
  switch (family) {
    case "bash":
      return str(input.description);
    case "edit":
    case "write":
    case "read":
      return str(input.file_path) ?? str(input.filePath) ?? str(input.notebook_path);
    case "search":
      return str(input.path) ?? str(input.glob);
    case "task":
      return str(input.subagent_type);
    case "mcp":
      return mcpServerName(name);
    default:
      return undefined;
  }
}

export function toolSubtitle(name: string, input: JsonObject): string | undefined {
  const full = toolSubtitleFull(name, input);
  if (full === undefined) return undefined;
  const family = toolFamily(name);
  if (family === "edit" || family === "write" || family === "read" || family === "search") {
    return shortenPath(full, 3);
  }
  return full;
}

export function toolVerb(name: string): string {
  const family = toolFamily(name);
  switch (family) {
    case "bash":
      return "Ran";
    case "edit":
      return "Edited";
    case "write":
      return "Wrote";
    case "read":
      return "Read";
    case "search":
      return name === "Glob" ? "Listed" : "Searched";
    case "web":
      return name === "WebFetch" ? "Fetched" : "Searched the web";
    case "todo":
      return "Plan";
    case "task":
      return "Delegated";
    case "workflow":
      return "Ran a workflow";
    case "mcp":
      return "Called";
    default:
      return "Ran";
  }
}

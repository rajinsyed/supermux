import type { JsonObject, UserLine } from "../protocol/types";
import { readTool, writeBlock } from "./blocks";
import { asString, isPlainObject, type TranscriptIndex } from "./helpers";
import { classifyToolStatus, extractTodos } from "./toolStatus";
import { startUserTurn } from "./turns";
import type { Block, ToolBlock, TranscriptModel } from "./types";

export function applyUser(
  model: TranscriptModel,
  index: TranscriptIndex,
  line: UserLine,
  nowMs: number
): TranscriptModel {
  if (line.uuid) {
    if (index.seenUuids.has(line.uuid)) return model;
    index.seenUuids.add(line.uuid);
  }
  if (line.isMeta) return model;
  const content = line.message.content;
  const parent = line.parent_tool_use_id ?? null;

  if (typeof content === "string") {
    if (parent || line.isReplay) return model;
    return startUserTurn(model, index, content, undefined, nowMs, line.uuid);
  }

  let next = model;
  for (const item of content ?? []) {
    if (item.type === "tool_result") {
      const result = item as { tool_use_id: string; content?: unknown; is_error?: boolean };
      next = applyToolResult(next, index, result.tool_use_id, result, line.tool_use_result, nowMs);
      continue;
    }
    if (item.type === "text") {
      const text = asString((item as { text?: string }).text) ?? "";
      if (parent) {
        next = appendSubagentText(next, index, parent, text, line.uuid);
        continue;
      }
      if (line.isReplay) continue;
      next = startUserTurn(next, index, text, undefined, nowMs, line.uuid);
    }
  }
  return next;
}

function appendSubagentText(
  model: TranscriptModel,
  index: TranscriptIndex,
  parentToolUseId: string,
  text: string,
  uuid?: string
): TranscriptModel {
  const found = readTool(model, index, parentToolUseId);
  if (!found) return model;
  const block: Block = {
    kind: "notice",
    key: `sub:${uuid ?? `${parentToolUseId}:${found.block.children.length}`}`,
    level: "info",
    text
  };
  return writeBlock(model, found.location, {
    ...found.block,
    children: found.block.children.concat(block)
  });
}

function applyToolResult(
  model: TranscriptModel,
  index: TranscriptIndex,
  toolUseId: string,
  result: { content?: unknown; is_error?: boolean },
  structured: JsonObject | undefined,
  nowMs: number
): TranscriptModel {
  const resolved = clearPendingForTool(model, toolUseId);
  const found = readTool(resolved, index, toolUseId);
  if (!found) return resolved;
  const text = stringifyToolResultContent(result.content);
  const status = classifyToolStatus(found.block.name, result.is_error === true, text, structured);
  const nextBlock: ToolBlock = {
    ...found.block,
    status,
    streaming: false,
    inputComplete: true,
    resultText: text,
    resultIsError: result.is_error === true,
    structured,
    endedAtMs: nowMs
  };
  let next = writeBlock(resolved, found.location, nextBlock);
  const todos = extractTodos(found.block.name, found.block.input, structured);
  if (todos) next = { ...next, todos, revision: next.revision + 1 };
  return next;
}

function clearPendingForTool(model: TranscriptModel, toolUseId: string): TranscriptModel {
  const pending = model.pending.filter((p) => p.request.tool_use_id !== toolUseId);
  if (pending.length === model.pending.length) return model;
  return { ...model, pending, revision: model.revision + 1 };
}

function stringifyToolResultContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (typeof part === "string") return part;
        if (isPlainObject(part) && typeof part.text === "string") return part.text;
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  if (content === undefined || content === null) return "";
  return JSON.stringify(content, null, 2);
}

import type { JsonObject, UserLine } from "../protocol/types";
import { readTool, writeBlock } from "./blocks";
import { asNumber, asString, isPlainObject, type TranscriptIndex } from "./helpers";
import { classifyToolStatus, extractTodos } from "./toolStatus";
import { startUserTurn } from "./turns";
import type {
  Block,
  SubagentInfo,
  SubagentToolStats,
  TaskRecord,
  ToolBlock,
  TranscriptModel
} from "./types";

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

/**
 * `tool_use_result` is where the launching turn learns what it launched: the
 * agent's own id/model/toolStats (AgentOutput), the workflow's runId
 * (WorkflowOutput), and the shell's backgroundTaskId (BashOutput). All three are
 * needed BEFORE any task frame arrives — the drill-in is keyed on runId+agentId,
 * and a workflow's task frames never carry the runId at all.
 */
function subagentFromResult(
  previous: SubagentInfo | undefined,
  structured: JsonObject | undefined
): SubagentInfo | undefined {
  if (!structured) return previous;
  const status = asString(structured.status);
  const taskId = asString(structured.taskId) ?? asString(structured.backgroundTaskId);
  const runId = asString(structured.runId);
  const agentId = asString(structured.agentId);
  const workflowName = asString(structured.workflowName);
  const model = asString(structured.resolvedModel);
  const raw = isPlainObject(structured.toolStats) ? structured.toolStats : undefined;
  const stats = raw
    ? ({
        readCount: asNumber(raw.readCount),
        searchCount: asNumber(raw.searchCount),
        bashCount: asNumber(raw.bashCount),
        editFileCount: asNumber(raw.editFileCount),
        linesAdded: asNumber(raw.linesAdded),
        linesRemoved: asNumber(raw.linesRemoved),
        otherToolCount: asNumber(raw.otherToolCount)
      } satisfies SubagentToolStats)
    : undefined;
  const backgroundedByUser = structured.backgroundedByUser === true;
  const timedOutAfterMs = asNumber(structured.timedOutAfterMs);
  const asyncLaunched = status === "async_launched";
  if (
    !taskId &&
    !runId &&
    !agentId &&
    !workflowName &&
    !model &&
    !stats &&
    !backgroundedByUser &&
    timedOutAfterMs === undefined
  ) {
    return previous;
  }
  return {
    ...previous,
    taskId: taskId ?? previous?.taskId,
    taskType: asString(structured.taskType) ?? previous?.taskType,
    agentId: agentId ?? previous?.agentId,
    subagentType: asString(structured.agentType) ?? previous?.subagentType,
    workflowName: workflowName ?? previous?.workflowName,
    workflowRunId: runId ?? previous?.workflowRunId,
    model: model ?? previous?.model,
    summary: asString(structured.summary) ?? previous?.summary,
    outputFile: asString(structured.outputFile) ?? previous?.outputFile,
    totalTokens: asNumber(structured.totalTokens) ?? previous?.totalTokens,
    toolUses: asNumber(structured.totalToolUseCount) ?? previous?.toolUses,
    durationMs: asNumber(structured.totalDurationMs) ?? previous?.durationMs,
    toolStats: stats ?? previous?.toolStats,
    backgroundedByUser: backgroundedByUser || previous?.backgroundedByUser,
    timedOutAfterMs: timedOutAfterMs ?? previous?.timedOutAfterMs,
    // A shell that came back with a backgroundTaskId IS in the background, and
    // an agent or workflow that answered `async_launched` is too — the strip's
    // own frame confirms it a beat later, but the card must not flicker plain in
    // between.
    background:
      previous?.background ||
      backgroundedByUser ||
      asyncLaunched ||
      asString(structured.backgroundTaskId) !== undefined ||
      undefined
  };
}

/**
 * The task record for a launch we learned about from `tool_use_result` rather
 * than a task frame. A workflow's runId arrives ONLY here, and the strip's
 * drill-in needs it, so it is folded into `tasksById` on the spot.
 */
function recordFromResult(
  previous: TaskRecord | undefined,
  info: SubagentInfo,
  nowMs: number
): TaskRecord | undefined {
  const taskId = info.taskId;
  if (!taskId) return undefined;
  return {
    ...previous,
    taskId,
    taskType: info.taskType ?? previous?.taskType,
    toolUseId: previous?.toolUseId,
    description: previous?.description ?? info.description,
    status: previous?.status,
    workflowName: info.workflowName ?? previous?.workflowName,
    workflowRunId: info.workflowRunId ?? previous?.workflowRunId,
    subagentType: info.subagentType ?? previous?.subagentType,
    summary: info.summary ?? previous?.summary,
    outputFile: info.outputFile ?? previous?.outputFile,
    totalTokens: previous?.totalTokens ?? info.totalTokens,
    toolUses: previous?.toolUses ?? info.toolUses,
    durationMs: previous?.durationMs ?? info.durationMs,
    isBackgrounded: previous?.isBackgrounded ?? info.background,
    startedAtMs: previous?.startedAtMs ?? nowMs,
    endedAtMs: previous?.endedAtMs,
    progressTick: previous?.progressTick ?? 0,
    workflow: previous?.workflow
  };
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
  const subagent = subagentFromResult(found.block.subagent, structured);
  const nextBlock: ToolBlock = {
    ...found.block,
    status,
    streaming: false,
    inputComplete: true,
    resultText: text,
    resultIsError: result.is_error === true,
    structured,
    subagent,
    endedAtMs: nowMs
  };
  let next = writeBlock(resolved, found.location, nextBlock);
  if (subagent?.taskId) {
    const record = recordFromResult(next.tasksById[subagent.taskId], subagent, nowMs);
    if (record) {
      next = {
        ...next,
        tasksById: { ...next.tasksById, [record.taskId]: { ...record, toolUseId } },
        revision: next.revision + 1
      };
    }
  }
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

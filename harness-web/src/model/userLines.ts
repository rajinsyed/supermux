import type { JsonObject, UserLine } from "../protocol/types";
import {
  applyAgentOutputToThread,
  applyUserToThread,
  reconcileSupersededAgentAttempts
} from "./agentThreads";
import { markTurnAborted, readTool, writeBlock } from "./blocks";
import { activeTurnIndex, asNumber, asString, isPlainObject, withTurn, type TranscriptIndex } from "./helpers";
import { classifyLocalUserText } from "./localText";
import { classifyToolStatus, extractTodos } from "./toolStatus";
import {
  appendCommandOutput,
  appendInterjection,
  startCommandTurn,
  startContinuationTurn,
  startUserTurn
} from "./turns";
import type {
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
  const atMs = frameTimeMs(line, nowMs);

  // One frame, two folds — the agent's own thread and the inline tree. The
  // thread pass runs first so a tool_result settles the thread's copy of the
  // block whether or not the inline copy is still on screen.
  let next = parent ? applyUserToThread(model, line, parent, nowMs) : model;

  if (typeof content === "string") {
    if (parent || line.isReplay) return next;
    if (line.mid_turn) return applyMidTurnText(next, index, content, line.uuid, atMs);
    return applyUserText(next, index, content, line.uuid, atMs);
  }

  for (const item of content ?? []) {
    if (item.type === "tool_result") {
      const result = item as { tool_use_id: string; content?: unknown; is_error?: boolean };
      next = applyToolResult(next, index, result.tool_use_id, result, line.tool_use_result, atMs);
      next = touchActiveTurn(next, atMs);
      continue;
    }
    if (item.type === "text") {
      const text = asString((item as { text?: string }).text) ?? "";
      // A forwarded subagent message belongs to its THREAD, which the pass above
      // already recorded. Round 3 also pasted it into the inline card as an
      // anonymous notice; round 4 does not, because the inline surface is now a
      // one-line row and the conversation is read in the agent view.
      if (parent) continue;
      if (line.isReplay) continue;
      if (line.mid_turn) {
        next = applyMidTurnText(next, index, text, line.uuid, atMs);
        continue;
      }
      next = applyUserText(next, index, text, line.uuid, atMs);
    }
  }
  return next;
}

/**
 * A replayed `queued_command` record: a message the user queued while a turn
 * ran, which the CLI consumed INSIDE that turn (its lifecycle frame says
 * "started" mid-stream and the same turn's remaining output answers it — see
 * the `command_lifecycle` case in transcript.ts, which handles the live wire).
 * On replay it files into the open turn as the interjected bubble it was;
 * opening a fresh turn for it would draw the question below its own answer.
 * With no turn open — the record somehow leads the replay — it falls back to
 * an ordinary user turn, because dropping typed text is never the answer.
 */
function applyMidTurnText(
  model: TranscriptModel,
  index: TranscriptIndex,
  text: string,
  uuid: string | undefined,
  atMs: number
): TranscriptModel {
  const cleaned = text.trim();
  if (cleaned.length === 0) return model;
  return (
    appendInterjection(model, uuid, text, undefined, atMs) ??
    startUserTurn(model, index, text, undefined, atMs, uuid)
  );
}

/**
 * The record's own clock when it has one. Replayed history arrives seconds or
 * days after it was written; opening its turns at wall-now gives every replayed
 * turn a zero-or-negative span and a "just now" start.
 */
function frameTimeMs(line: UserLine, nowMs: number): number {
  const stamp = line.timestamp ? Date.parse(line.timestamp) : Number.NaN;
  return Number.isFinite(stamp) ? stamp : nowMs;
}

/**
 * Record when the open turn last received a frame — the time `closeOpenTurns`
 * settles it at when no `result` ever arrives (replayed history, a crash).
 * tool_result frames go through here because they extend the turn's work
 * without opening or closing anything.
 */
function touchActiveTurn(model: TranscriptModel, atMs: number): TranscriptModel {
  const open = activeTurnIndex(model);
  if (open < 0) return model;
  const turn = model.turns[open];
  if (turn.lastFrameAtMs === atMs) return model;
  return withTurn(model, open, { ...turn, lastFrameAtMs: atMs });
}

/**
 * One user-side text, routed by what it actually is. The transcript files
 * several MACHINE-AUTHORED records as plain `user` lines — slash-command
 * invocations, their stdout, caveat scaffolding, task notifications, interrupt
 * markers, compact-continuation preambles — and rendering those as chat bubbles
 * of raw XML is the round-5 resume screenshot. Only `plain` opens an ordinary
 * user turn.
 */
function applyUserText(
  model: TranscriptModel,
  index: TranscriptIndex,
  text: string,
  uuid: string | undefined,
  atMs: number
): TranscriptModel {
  const classified = classifyLocalUserText(text);
  switch (classified.kind) {
    case "hidden":
      return model;
    case "command":
      return startCommandTurn(model, index, classified.name, classified.args, atMs, uuid);
    case "commandOutput":
      return appendCommandOutput(model, classified.text, `cmdout:${uuid ?? model.revision}`, atMs);
    case "continued":
      return startContinuationTurn(model, index, atMs, uuid);
    case "interrupt": {
      // "[Request interrupted by user]" is the transcript's record of an abort.
      // The live wire reports the same fact through `result`/`aborted` frames;
      // this record is what a REPLAY has. The still-open turn is marked aborted
      // — the boundary the user saw — and no bubble is drawn for the marker.
      const open = activeTurnIndex(model);
      if (open < 0) return model;
      return withTurn(model, open, markTurnAborted(model.turns[open], atMs));
    }
    default:
      return startUserTurn(model, index, text, undefined, atMs, uuid);
  }
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
  structured: JsonObject | undefined,
  toolStatus: ToolBlock["status"]
): SubagentInfo | undefined {
  if (!structured && !previous) return undefined;
  const output = structured ?? {};
  const structuredStatus = asString(output.status);
  const status =
    structuredStatus === "completed" || structuredStatus === "success"
      ? "completed"
      : structuredStatus === "failed" || structuredStatus === "error"
        ? "failed"
        : structuredStatus === "killed"
          ? "killed"
          : structuredStatus === "stopped" || structuredStatus === "aborted"
            ? "stopped"
            : toolStatus === "error"
              ? "failed"
              : toolStatus === "aborted"
                ? "stopped"
                : previous?.status;
  const taskId = asString(output.taskId) ?? asString(output.backgroundTaskId);
  const runId = asString(output.runId);
  const agentId = asString(output.agentId);
  const workflowName = asString(output.workflowName);
  const model = asString(output.resolvedModel);
  const raw = isPlainObject(output.toolStats) ? output.toolStats : undefined;
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
  const backgroundedByUser = output.backgroundedByUser === true;
  const timedOutAfterMs = asNumber(output.timedOutAfterMs);
  const asyncLaunched = structuredStatus === "async_launched";
  if (
    !taskId &&
    !runId &&
    !agentId &&
    !workflowName &&
    !model &&
    !stats &&
    !backgroundedByUser &&
    timedOutAfterMs === undefined &&
    status === previous?.status
  ) {
    return previous;
  }
  return {
    ...previous,
    taskId: taskId ?? previous?.taskId,
    taskType: asString(output.taskType) ?? previous?.taskType,
    agentId: agentId ?? previous?.agentId,
    subagentType: asString(output.agentType) ?? previous?.subagentType,
    workflowName: workflowName ?? previous?.workflowName,
    workflowRunId: runId ?? previous?.workflowRunId,
    model: model ?? previous?.model,
    status,
    summary: asString(output.summary) ?? previous?.summary,
    outputFile: asString(output.outputFile) ?? previous?.outputFile,
    totalTokens: asNumber(output.totalTokens) ?? previous?.totalTokens,
    toolUses: asNumber(output.totalToolUseCount) ?? previous?.toolUses,
    durationMs: asNumber(output.totalDurationMs) ?? previous?.durationMs,
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
      asString(output.backgroundTaskId) !== undefined ||
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
  const subagent = subagentFromResult(found.block.subagent, structured, status);
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
  // The Agent tool_result lands on the MAIN turn (parent null), so this is
  // where a thread learns its model, agentId and final tallies when no task
  // frame carried them.
  next = applyAgentOutputToThread(next, toolUseId, structured, status, nowMs);
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
  return reconcileSupersededAgentAttempts(next);
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

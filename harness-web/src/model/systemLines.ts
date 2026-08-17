import type { SystemLine } from "../protocol/types";
import { evictUuids, readTool, writeBlock } from "./blocks";
import {
  activeTurnIndex,
  asNumber,
  asString,
  blockAtPath,
  isPlainObject,
  permissionModeOf,
  withTurn,
  type TranscriptIndex
} from "./helpers";
import { hasLiveBackgroundWork, isTaskSettled } from "./tasks";
import { appendNotice, pushBanner, resetConversation } from "./turns";
import { mergeWorkflowProgress } from "./workflow";
import type {
  Block,
  BackgroundTask,
  SubagentInfo,
  TaskRecord,
  ThinkingBlock,
  ToolBlock,
  TranscriptModel,
  Turn
} from "./types";

export function applySystem(
  model: TranscriptModel,
  index: TranscriptIndex,
  line: SystemLine,
  nowMs: number
): TranscriptModel {
  const raw = line as unknown as Record<string, unknown>;
  switch (asString(raw.subtype)) {
    case "init":
      return applyInit(model, raw);
    case "status":
      return applyStatus(model, raw, nowMs);
    case "session_state_changed": {
      const state = raw.state;
      if (state !== "idle" && state !== "running" && state !== "requires_action") return model;
      return { ...model, activity: { ...model.activity, sessionState: state }, revision: model.revision + 1 };
    }
    case "compact_boundary":
      return applyCompactBoundary(model, raw);
    case "conversation_reset":
      return resetConversation(model, index);
    case "thinking_tokens":
      return applyThinkingTokens(model, raw);
    case "api_retry":
      return applyApiRetry(model, raw, nowMs);
    case "informational":
    case "notification": {
      const content = asString(raw.content) ?? asString(raw.message);
      if (!content) return model;
      const level = raw.level === "error" ? "error" : raw.level === "warning" ? "warning" : "info";
      return pushBanner(model, level, content, undefined, nowMs);
    }
    case "permission_denied":
      return appendNotice(
        model,
        "warning",
        asString(raw.content) ?? asString(raw.message) ?? "Permission denied",
        `denied:${asString(raw.uuid) ?? model.revision}`
      );
    case "local_command_output": {
      const content = asString(raw.content);
      if (!content) return model;
      return appendNotice(model, "info", content, `local:${asString(raw.uuid) ?? model.revision}`);
    }
    case "model_refusal_fallback":
      return evictUuids(model, new Set((raw.retracted_message_uuids as string[]) ?? []));
    case "task_started":
    case "task_progress":
    case "task_updated":
    case "task_notification":
      return applyTaskLine(model, index, raw, nowMs);
    case "background_tasks_changed":
      return applyBackgroundTasks(model, raw, nowMs);
    default:
      return model;
  }
}

function applyInit(model: TranscriptModel, raw: Record<string, unknown>): TranscriptModel {
  const session = { ...model.session };
  session.sessionId = asString(raw.session_id) ?? session.sessionId;
  session.cwd = asString(raw.cwd) ?? session.cwd;
  session.model = asString(raw.model) ?? session.model;
  session.permissionMode = permissionModeOf(raw.permissionMode) ?? session.permissionMode;
  session.tools = (raw.tools as string[]) ?? session.tools;
  session.slashCommands = (raw.slash_commands as string[]) ?? session.slashCommands;
  session.mcpServers = (raw.mcp_servers as never) ?? session.mcpServers;
  session.agents = (raw.agents as string[]) ?? session.agents;
  session.skills = (raw.skills as string[]) ?? session.skills;
  session.cliVersion = asString(raw.claude_code_version) ?? session.cliVersion;
  session.capabilities = (raw.capabilities as string[]) ?? session.capabilities;
  session.outputStyle = asString(raw.output_style) ?? session.outputStyle;
  return { ...model, session, revision: model.revision + 1 };
}

function applyStatus(
  model: TranscriptModel,
  raw: Record<string, unknown>,
  nowMs: number
): TranscriptModel {
  const status = raw.status === "requesting" || raw.status === "compacting" ? raw.status : null;
  const mode = permissionModeOf(raw.permissionMode);
  let next: TranscriptModel = {
    ...model,
    activity: { ...model.activity, status },
    session: mode ? { ...model.session, permissionMode: mode } : model.session,
    revision: model.revision + 1
  };
  const compactError = asString(raw.compact_error);
  if (compactError) next = pushBanner(next, "warning", compactError, undefined, nowMs);
  return next;
}

function applyCompactBoundary(model: TranscriptModel, raw: Record<string, unknown>): TranscriptModel {
  const meta = isPlainObject(raw.compact_metadata) ? raw.compact_metadata : undefined;
  const divider: Block = {
    kind: "divider",
    key: `compact:${asString(raw.uuid) ?? model.revision}`,
    variant: "compact",
    trigger: asString(meta?.trigger),
    preTokens: asNumber(meta?.pre_tokens)
  };
  const target = model.turns.length - 1;
  if (target < 0) return model;
  const turn = model.turns[target];
  return withTurn(model, target, {
    ...turn,
    blocks: turn.blocks.concat(divider),
    revision: turn.revision + 1
  });
}

function applyThinkingTokens(model: TranscriptModel, raw: Record<string, unknown>): TranscriptModel {
  const tokens = asNumber(raw.estimated_tokens) ?? 0;
  const next: TranscriptModel = {
    ...model,
    activity: { ...model.activity, thinkingTokens: tokens },
    revision: model.revision + 1
  };
  const turnIndex = activeTurnIndex(next);
  if (turnIndex < 0) return next;
  const turn = next.turns[turnIndex];
  const path = findStreamingThinking(turn);
  if (!path) return next;
  const block = blockAtPath(turn, path) as ThinkingBlock | undefined;
  if (!block) return next;
  return writeBlock(next, { turnIndex, path }, { ...block, tokens });
}

function applyApiRetry(
  model: TranscriptModel,
  raw: Record<string, unknown>,
  nowMs: number
): TranscriptModel {
  const attempt = asNumber(raw.attempt) ?? 1;
  const banner = {
    id: `retry:${attempt}:${asString(raw.uuid) ?? model.revision}`,
    severity: "warning" as const,
    title: asString(raw.error) ?? "Request failed — retrying",
    createdAtMs: nowMs,
    retry: {
      attempt,
      maxRetries: asNumber(raw.max_retries),
      retryDelayMs: asNumber(raw.retry_delay_ms)
    }
  };
  return { ...model, banners: model.banners.concat(banner).slice(-5), revision: model.revision + 1 };
}

/**
 * REPLACE, per the SDK: this frame carries the WHOLE background set every time,
 * and an empty array means nothing is left. Membership therefore comes from here
 * and nowhere else — `task_started` fires for foreground Bash too, so a strip
 * fed from task frames would list every command the session has ever run.
 *
 * Detail comes from `tasksById`, so a row keeps its status, activity and metrics
 * even when the frame itself carries nothing but an id and a description.
 */
function applyBackgroundTasks(
  model: TranscriptModel,
  raw: Record<string, unknown>,
  nowMs: number
): TranscriptModel {
  const tasks = Array.isArray(raw.tasks) ? raw.tasks : [];
  const rows: BackgroundTask[] = [];
  for (const task of tasks) {
    if (!isPlainObject(task)) continue;
    const t = task as Record<string, unknown>;
    const taskId = asString(t.task_id);
    if (!taskId) continue;
    const usage = isPlainObject(t.usage) ? t.usage : undefined;
    const record = model.tasksById[taskId];
    rows.push({
      taskId,
      taskType: asString(t.task_type) ?? record?.taskType,
      description: asString(t.description) ?? record?.description,
      subagentType: asString(t.subagent_type) ?? record?.subagentType,
      status: asString(t.status) ?? record?.status,
      totalTokens: asNumber(usage?.total_tokens) ?? record?.totalTokens,
      toolUses: asNumber(usage?.tool_uses) ?? record?.toolUses,
      durationMs: asNumber(usage?.duration_ms) ?? record?.durationMs
    });
  }
  // Membership in the strip is what makes a task "backgrounded", so the record
  // learns it here — a Bash card only earns its badge once the CLI says the
  // command is in the background set. This frame RACES `task_started`: on both
  // the shells and the workflow probe it arrives first, so a row with no record
  // yet seeds one rather than losing the flag.
  let tasksById = model.tasksById;
  for (const row of rows) {
    const record = tasksById[row.taskId];
    if (record?.isBackgrounded) continue;
    if (tasksById === model.tasksById) tasksById = { ...tasksById };
    tasksById[row.taskId] = record
      ? { ...record, isBackgrounded: true }
      : {
          taskId: row.taskId,
          taskType: row.taskType,
          description: row.description,
          subagentType: row.subagentType,
          status: row.status,
          totalTokens: row.totalTokens,
          toolUses: row.toolUses,
          durationMs: row.durationMs,
          isBackgrounded: true,
          startedAtMs: nowMs,
          progressTick: 0
        };
  }
  return { ...model, backgroundTasks: rows, tasksById, revision: model.revision + 1 };
}

function taskStatusFrom(
  subtype: string | undefined,
  raw: Record<string, unknown>,
  patch: Record<string, unknown> | undefined,
  previous: string | undefined
): string | undefined {
  return (
    asString(raw.status) ??
    asString(patch?.status) ??
    (subtype === "task_started" ? "running" : previous)
  );
}

const TERMINAL_STATUSES = new Set(["completed", "failed", "killed", "stopped"]);

/**
 * `task_updated` sends a MERGE patch: only the keys that changed. Every absent
 * key therefore has to keep its previous value, which is why this walks the
 * patch rather than reconstructing the record from the frame.
 */
function mergeTaskRecord(
  previous: TaskRecord | undefined,
  taskId: string,
  subtype: string | undefined,
  raw: Record<string, unknown>,
  nowMs: number
): TaskRecord {
  const usage = isPlainObject(raw.usage) ? raw.usage : undefined;
  const patch = isPlainObject(raw.patch) ? raw.patch : undefined;
  const status = taskStatusFrom(subtype, raw, patch, previous?.status);
  const description =
    // A `task_progress` description is the CURRENT ACTIVITY ("Gather: agent-beta"),
    // not the task's name — overwriting the description with it renames the row
    // in the strip several times a second.
    subtype === "task_progress"
      ? previous?.description ?? asString(raw.summary)
      : asString(raw.description) ?? asString(patch?.description) ?? previous?.description;
  const workflow = mergeWorkflowProgress(previous?.workflow, raw.workflow_progress, {
    name: asString(raw.workflow_name) ?? previous?.workflowName,
    runId: previous?.workflowRunId,
    status
  });
  const ended =
    asNumber(patch?.end_time) ??
    (status !== undefined && TERMINAL_STATUSES.has(status)
      ? previous?.endedAtMs ?? nowMs
      : previous?.endedAtMs);
  return {
    taskId,
    taskType: asString(raw.task_type) ?? previous?.taskType,
    toolUseId: asString(raw.tool_use_id) ?? previous?.toolUseId,
    description,
    status,
    workflowName: asString(raw.workflow_name) ?? previous?.workflowName,
    workflowRunId: previous?.workflowRunId,
    subagentType: asString(raw.subagent_type) ?? previous?.subagentType,
    activity: subtype === "task_progress" ? asString(raw.description) : previous?.activity,
    lastToolName: asString(raw.last_tool_name) ?? previous?.lastToolName,
    summary: asString(raw.summary) ?? previous?.summary,
    error: asString(raw.error) ?? asString(patch?.error) ?? previous?.error,
    outputFile: asString(raw.output_file) ?? previous?.outputFile,
    totalTokens: asNumber(usage?.total_tokens) ?? previous?.totalTokens,
    toolUses: asNumber(usage?.tool_uses) ?? previous?.toolUses,
    durationMs: asNumber(usage?.duration_ms) ?? previous?.durationMs,
    isBackgrounded:
      patch?.is_backgrounded === true ? true : patch?.is_backgrounded === false ? false : previous?.isBackgrounded,
    startedAtMs: previous?.startedAtMs ?? nowMs,
    endedAtMs: ended,
    progressTick: (previous?.progressTick ?? 0) + 1,
    workflow
  };
}

function subagentFrom(previous: SubagentInfo | undefined, record: TaskRecord): SubagentInfo {
  return {
    ...previous,
    taskId: record.taskId,
    taskType: record.taskType ?? previous?.taskType,
    subagentType: record.subagentType ?? previous?.subagentType,
    description: record.description ?? previous?.description,
    status: record.status ?? previous?.status,
    lastToolName: record.lastToolName ?? previous?.lastToolName,
    activity: record.activity ?? previous?.activity,
    summary: record.summary ?? previous?.summary,
    outputFile: record.outputFile ?? previous?.outputFile,
    totalTokens: record.totalTokens ?? previous?.totalTokens,
    toolUses: record.toolUses ?? previous?.toolUses,
    durationMs: record.durationMs ?? previous?.durationMs,
    workflowName: record.workflowName ?? previous?.workflowName,
    workflowRunId: record.workflowRunId ?? previous?.workflowRunId,
    background: record.isBackgrounded ?? previous?.background,
    progressTick: record.progressTick
  };
}

/**
 * Task frames write `tasksById` and — when the launching tool call is on screen
 * — the ToolBlock they belong to. They never open, reopen, or settle a TURN, and
 * they never touch `sessionState`.
 *
 * That is load-bearing rather than incidental. A workflow's `result` arrives the
 * instant it is launched and its task frames keep coming for another ten
 * seconds; the same is true of every background shell. If those frames reopened
 * the turn, the pane would claim Claude was still working long after it had
 * answered, the Stop button would stay up, and every send would queue behind
 * activity that ends nowhere. Post-result task activity is reported by the tasks
 * strip, which is exactly what it is for.
 */
function applyTaskLine(
  model: TranscriptModel,
  index: TranscriptIndex,
  raw: Record<string, unknown>,
  nowMs: number
): TranscriptModel {
  const subtype = asString(raw.subtype);
  const taskId = asString(raw.task_id);
  let toolUseId = asString(raw.tool_use_id);
  if (taskId && toolUseId) index.taskToTool.set(taskId, toolUseId);
  if (!toolUseId && taskId) toolUseId = index.taskToTool.get(taskId);
  if (!taskId) return applyTaskToBlock(model, index, toolUseId, raw, subtype, undefined, nowMs);

  const previous = model.tasksById[taskId];
  const record = mergeTaskRecord(
    previous ? { ...previous, toolUseId: previous.toolUseId ?? toolUseId } : undefined,
    taskId,
    subtype,
    { ...raw, tool_use_id: toolUseId },
    nowMs
  );
  let next: TranscriptModel = {
    ...model,
    tasksById: { ...model.tasksById, [taskId]: record },
    revision: model.revision + 1
  };
  // The strip's own row detail is refreshed from the record, so a task that is
  // in the background set shows live status without waiting for the CLI to
  // resend the whole set.
  if (next.backgroundTasks.some((task) => task.taskId === taskId)) {
    next = {
      ...next,
      backgroundTasks: next.backgroundTasks.map((task) =>
        task.taskId === taskId
          ? {
              ...task,
              taskType: record.taskType ?? task.taskType,
              description: record.description ?? task.description,
              status: record.status ?? task.status,
              totalTokens: record.totalTokens ?? task.totalTokens,
              toolUses: record.toolUses ?? task.toolUses,
              durationMs: record.durationMs ?? task.durationMs
            }
          : task
      )
    };
  }
  next = applyTaskToBlock(next, index, toolUseId, raw, subtype, record, nowMs);
  if (isTaskSettled(record.status)) next = applyDeferredFolds(next);
  if (subtype === "task_notification") next = announceTaskFinished(next, record, nowMs);
  return next;
}

/**
 * Honour a fold that a `result` had to postpone.
 *
 * A turn that launched a workflow completes while its agents keep running, so
 * folding it on the result frame would hide the live card mid-flight. The intent
 * is recorded instead and applied here, once nothing the turn owns is running.
 */
function applyDeferredFolds(model: TranscriptModel): TranscriptModel {
  let changed = false;
  const turns = model.turns.map((turn) => {
    if (!turn.foldWhenTasksSettle || hasLiveBackgroundWork(turn)) return turn;
    changed = true;
    return { ...turn, folded: true, foldWhenTasksSettle: undefined, revision: turn.revision + 1 };
  });
  return changed ? { ...model, turns, revision: model.revision + 1 } : model;
}

function applyTaskToBlock(
  model: TranscriptModel,
  index: TranscriptIndex,
  toolUseId: string | undefined,
  raw: Record<string, unknown>,
  subtype: string | undefined,
  record: TaskRecord | undefined,
  nowMs: number
): TranscriptModel {
  if (!toolUseId) return model;
  const found = readTool(model, index, toolUseId);
  if (!found) return model;
  const prev = found.block.subagent;
  const subagent = record
    ? subagentFrom(prev, record)
    : subagentFrom(prev, mergeTaskRecord(undefined, "", subtype, raw, nowMs));
  const status = subagent.status;
  const workflow =
    record?.workflow ??
    mergeWorkflowProgress(found.block.workflow, raw.workflow_progress, {
      name: asString(raw.workflow_name) ?? found.block.workflow?.name,
      runId: found.block.workflow?.runId,
      status
    });
  // A subagent card settles on the task's terminal edge because its own
  // tool_result may never arrive (an async agent answers `async_launched` and
  // then runs on). Every terminal status settles it — the CLI's kill sequence
  // ends in `stopped`, and a block that only settles on completed/failed spins
  // forever on a task the user just killed. A workflow does NOT settle its card
  // here: its tool_result already landed, and the card is a live progress
  // surface after that (the `running` guard is what keeps it out).
  const finished = isTaskSettled(status);
  const running = found.block.status === "running" || found.block.status === "pending";
  const settledStatus =
    status === "failed" ? "error" : status === "completed" ? "success" : "aborted";
  const nextBlock: ToolBlock = {
    ...found.block,
    subagent,
    workflow,
    status: finished && running ? settledStatus : found.block.status,
    endedAtMs: finished && running ? found.block.endedAtMs ?? nowMs : found.block.endedAtMs
  };
  return writeBlock(model, found.location, nextBlock);
}

/**
 * The CLI's "background task finished" toast. Only for tasks that were actually
 * IN the background set: a foreground Bash gets a task_notification too, and its
 * result is already rendered on the card the user is looking at.
 */
function announceTaskFinished(
  model: TranscriptModel,
  record: TaskRecord,
  nowMs: number
): TranscriptModel {
  if (!record.isBackgrounded) return model;
  const subject = record.summary ?? record.description;
  if (!subject) return model;
  // The subject alone is the task's own description — "Print six ticks with
  // 4-second sleeps" — which says nothing about WHY it is being announced. The
  // outcome is the news; the description is which task it happened to.
  const outcome =
    record.status === "failed"
      ? "supermux.harness.notice.taskFailed"
      : record.status === "killed" || record.status === "stopped"
        ? "supermux.harness.notice.taskStopped"
        : "supermux.harness.notice.taskFinished";
  const severity = record.status === "failed" ? "warning" : "info";
  return pushBanner(model, severity, subject, undefined, nowMs, outcome);
}

function findStreamingThinking(turn: Turn): number[] | undefined {
  const walk = (blocks: Block[], prefix: number[]): number[] | undefined => {
    for (let i = blocks.length - 1; i >= 0; i -= 1) {
      const block = blocks[i];
      const path = prefix.concat(i);
      if (block.kind === "tool") {
        const nested = walk(block.children, path);
        if (nested) return nested;
      }
      if (block.kind === "thinking" && block.streaming) return path;
    }
    return undefined;
  };
  return walk(turn.blocks, []);
}

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
import { appendNotice, pushBanner, resetConversation } from "./turns";
import type { Block, ThinkingBlock, ToolBlock, TranscriptModel, Turn } from "./types";

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
      return applyBackgroundTasks(model, raw);
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

function applyBackgroundTasks(model: TranscriptModel, raw: Record<string, unknown>): TranscriptModel {
  const tasks = Array.isArray(raw.tasks) ? raw.tasks : [];
  return {
    ...model,
    backgroundTasks: tasks.map((task) => {
      const t = task as Record<string, unknown>;
      const usage = isPlainObject(t.usage) ? t.usage : undefined;
      return {
        taskId: asString(t.task_id) ?? "",
        description: asString(t.description),
        subagentType: asString(t.subagent_type),
        status: asString(t.status),
        totalTokens: asNumber(usage?.total_tokens),
        toolUses: asNumber(usage?.tool_uses),
        durationMs: asNumber(usage?.duration_ms)
      };
    }),
    revision: model.revision + 1
  };
}

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
  if (!toolUseId) return model;
  const found = readTool(model, index, toolUseId);
  if (!found) return model;
  const usage = isPlainObject(raw.usage) ? raw.usage : undefined;
  const patch = isPlainObject(raw.patch) ? raw.patch : undefined;
  const prev = found.block.subagent;
  const status =
    asString(raw.status) ??
    asString(patch?.status) ??
    (subtype === "task_started" ? "running" : prev?.status);
  const subagent = {
    ...prev,
    taskId: taskId ?? prev?.taskId,
    subagentType: asString(raw.subagent_type) ?? prev?.subagentType,
    description:
      subtype === "task_progress" ? prev?.description : asString(raw.description) ?? prev?.description,
    status,
    lastToolName: asString(raw.last_tool_name) ?? prev?.lastToolName,
    activity: subtype === "task_progress" ? asString(raw.description) : prev?.activity,
    summary: asString(raw.summary) ?? prev?.summary,
    outputFile: asString(raw.output_file) ?? prev?.outputFile,
    totalTokens: asNumber(usage?.total_tokens) ?? prev?.totalTokens,
    toolUses: asNumber(usage?.tool_uses) ?? prev?.toolUses,
    durationMs: asNumber(usage?.duration_ms) ?? prev?.durationMs,
    background: prev?.background ?? asString(raw.task_type) === "background"
  };
  const finished = status === "completed" || status === "failed";
  const running = found.block.status === "running" || found.block.status === "pending";
  const nextBlock: ToolBlock = {
    ...found.block,
    subagent,
    status: finished && running ? (status === "failed" ? "error" : "success") : found.block.status,
    endedAtMs: finished ? found.block.endedAtMs ?? nowMs : found.block.endedAtMs
  };
  return writeBlock(model, found.location, nextBlock);
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

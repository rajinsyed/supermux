import type {
  AssistantLine,
  ControlRequestLine,
  JsonObject,
  NativeEvent,
  ProtocolLine,
  ResultLine,
  StreamEventLine,
  SystemLine,
  UserLine
} from "../protocol/types";
import { markTurnAborted, settleTurn } from "./blocks";
import {
  activeTurnIndex,
  asString,
  createIndex as makeIndex,
  findTurnIndex,
  isPlainObject,
  permissionKindFor,
  permissionModeOf,
  unresolvedTurnIndex,
  withTurn,
  type TranscriptIndex
} from "./helpers";
import { applyAssistant } from "./assistantLines";
import { applyStreamEvent } from "./streamEvents";
import { applyUser } from "./userLines";
import { applySystem } from "./systemLines";
import { closeOpenTurns, createModel, resetConversation, startUserTurn } from "./turns";
import type { LocalAction, TranscriptModel, Turn } from "./types";

export { createIndex } from "./helpers";
export type { TranscriptIndex } from "./helpers";
export { createModel } from "./turns";

export function applyEvents(
  model: TranscriptModel,
  index: TranscriptIndex,
  events: NativeEvent[],
  nowMs: number
): TranscriptModel {
  let next = model;
  for (const event of events) next = applyEvent(next, index, event, nowMs);
  return next;
}

export function applyEvent(
  model: TranscriptModel,
  index: TranscriptIndex,
  event: NativeEvent,
  nowMs: number
): TranscriptModel {
  switch (event.kind) {
    case "protocol":
      return applyLine(model, index, event.line, nowMs);
    case "runStarted":
      return {
        ...model,
        runPhase: "running",
        runId: event.runId,
        exitError: undefined,
        revision: model.revision + 1
      };
    case "runExited": {
      const closed = closeOpenTurns(model, nowMs, event.status === 0 ? "complete" : "error");
      return {
        ...closed,
        runPhase: "exited",
        exitError: event.error,
        activity: { ...closed.activity, sessionState: "idle", status: null },
        pending: [],
        revision: closed.revision + 1
      };
    }
    case "stderr":
      return { ...model, stderrTail: model.stderrTail.concat(event.text).slice(-40) };
    default:
      return model;
  }
}

export function applyLine(
  model: TranscriptModel,
  index: TranscriptIndex,
  line: ProtocolLine,
  nowMs: number
): TranscriptModel {
  switch ((line as { type?: string }).type) {
    case "system":
      return applySystem(model, index, line as SystemLine, nowMs);
    case "stream_event":
      return applyStreamEvent(model, index, line as StreamEventLine, nowMs);
    case "assistant":
      return applyAssistant(model, index, line as AssistantLine, nowMs);
    case "user":
      return applyUser(model, index, line as UserLine, nowMs);
    case "result":
      return applyResult(model, index, line as ResultLine, nowMs);
    case "control_request":
      return applyControlRequest(model, line as ControlRequestLine, nowMs);
    case "control_cancel_request": {
      const requestId = (line as { request_id?: string }).request_id;
      if (!requestId) return model;
      return {
        ...model,
        pending: model.pending.filter((p) => p.requestId !== requestId),
        revision: model.revision + 1
      };
    }
    case "control_response":
      return applyControlResponse(model, line as { response?: { response?: JsonObject } });
    default:
      return model;
  }
}

function applyControlResponse(
  model: TranscriptModel,
  line: { response?: { response?: JsonObject } }
): TranscriptModel {
  const payload = line.response?.response;
  if (!isPlainObject(payload)) return model;
  const session = { ...model.session };
  let changed = false;
  if (Array.isArray(payload.models)) {
    session.models = payload.models as never;
    changed = true;
  }
  if (Array.isArray(payload.commands)) {
    session.commands = payload.commands as never;
    changed = true;
  }
  const mode = permissionModeOf(payload.current_permission_mode);
  if (mode) {
    session.permissionMode = mode;
    changed = true;
  }
  const outputStyle = asString(payload.output_style);
  if (outputStyle) {
    session.outputStyle = outputStyle;
    changed = true;
  }
  return changed ? { ...model, session, revision: model.revision + 1 } : model;
}

function applyResult(
  model: TranscriptModel,
  index: TranscriptIndex,
  line: ResultLine,
  nowMs: number
): TranscriptModel {
  if (line.uuid) {
    if (index.seenUuids.has(line.uuid)) return model;
    index.seenUuids.add(line.uuid);
  }
  const turnIndex = unresolvedTurnIndex(model);
  const aborted =
    line.subtype === "error_during_execution" && (line.terminal_reason ?? "").startsWith("aborted");
  const delta = line.usage ?? {};
  // `total_cost_usd` is the CLI's running session total, not this turn's spend:
  // in the reference trace the three results carry 0.2286 → 0.3238 → 0.3585,
  // each equal to its own cumulative `modelUsage[*].costUSD`. So the header
  // takes the latest value as-is, and the per-turn footer takes the delta
  // against the previous result. Take the max so a session that resumes into a
  // lower reported total never walks the header backwards.
  const previousCost = model.usage.costUsd;
  const reportedCost = line.total_cost_usd;
  const costUsd =
    reportedCost === undefined ? previousCost : Math.max(previousCost, reportedCost);
  const costDeltaUsd = reportedCost === undefined ? undefined : Math.max(0, reportedCost - previousCost);
  const usage = {
    costUsd,
    inputTokens: model.usage.inputTokens + (delta.input_tokens ?? 0),
    outputTokens: model.usage.outputTokens + (delta.output_tokens ?? 0),
    thinkingTokens: model.usage.thinkingTokens + (delta.output_tokens_details?.thinking_tokens ?? 0),
    cacheReadTokens: model.usage.cacheReadTokens + (delta.cache_read_input_tokens ?? 0),
    cacheCreationTokens: model.usage.cacheCreationTokens + (delta.cache_creation_input_tokens ?? 0),
    turns: model.usage.turns + 1
  };
  const next: TranscriptModel = {
    ...model,
    usage,
    activity: { ...model.activity, status: null, thinkingTokens: 0 },
    revision: model.revision + 1
  };
  if (turnIndex < 0) return next;
  const turn = next.turns[turnIndex];
  const settled = aborted ? markTurnAborted(turn, nowMs) : settleTurn(turn, nowMs);
  const state: Turn["state"] = aborted ? "aborted" : line.is_error ? "error" : "complete";
  return withTurn(next, turnIndex, {
    ...settled,
    state,
    result: {
      subtype: line.subtype,
      isError: line.is_error === true,
      text: line.result,
      durationMs: line.duration_ms,
      numTurns: line.num_turns,
      totalCostUsd: reportedCost,
      costDeltaUsd,
      terminalReason: line.terminal_reason,
      inputTokens: delta.input_tokens,
      outputTokens: delta.output_tokens,
      thinkingTokens: delta.output_tokens_details?.thinking_tokens,
      cacheReadTokens: delta.cache_read_input_tokens,
      cacheCreationTokens: delta.cache_creation_input_tokens
    },
    errorText: settled.errorText ?? (line.is_error && !aborted ? line.result : undefined),
    folded: state === "complete"
  });
}

function applyControlRequest(
  model: TranscriptModel,
  line: ControlRequestLine,
  nowMs: number
): TranscriptModel {
  const request = line.request as { subtype?: string; tool_name?: string };
  if (request.subtype !== "can_use_tool") return model;
  if (model.pending.some((p) => p.requestId === line.request_id)) return model;
  return {
    ...model,
    pending: model.pending.concat({
      requestId: line.request_id,
      kind: permissionKindFor(request.tool_name ?? ""),
      request: line.request as never,
      receivedAtMs: nowMs
    }),
    activity: { ...model.activity, sessionState: "requires_action" },
    revision: model.revision + 1
  };
}

export function applyLocalAction(
  model: TranscriptModel,
  index: TranscriptIndex,
  action: LocalAction,
  nowMs: number
): TranscriptModel {
  switch (action.kind) {
    case "localSend": {
      const busy = model.activity.sessionState !== "idle" || activeTurnIndex(model) >= 0;
      if (busy) {
        return {
          ...model,
          queued: model.queued.concat({
            uuid: action.uuid,
            text: action.text,
            images: action.images,
            queuedAtMs: action.atMs
          }),
          revision: model.revision + 1
        };
      }
      return startUserTurn(model, index, action.text, action.images, action.atMs, action.uuid);
    }
    case "cancelQueued":
      return {
        ...model,
        queued: model.queued.filter((q) => q.uuid !== action.uuid),
        revision: model.revision + 1
      };
    case "permissionResolved":
      return {
        ...model,
        pending: model.pending.filter((p) => p.requestId !== action.requestId),
        revision: model.revision + 1
      };
    case "contextUsage":
      return { ...model, contextUsage: action.usage, revision: model.revision + 1 };
    case "setTitle":
      return { ...model, session: { ...model.session, title: action.title }, revision: model.revision + 1 };
    case "setModel":
      return {
        ...model,
        session: { ...model.session, model: action.model, effort: action.effort },
        revision: model.revision + 1
      };
    case "setPermissionMode":
      return {
        ...model,
        session: { ...model.session, permissionMode: action.mode },
        revision: model.revision + 1
      };
    case "dismissBanner":
      return {
        ...model,
        banners: model.banners.filter((b) => b.id !== action.id),
        revision: model.revision + 1
      };
    case "toggleFold": {
      const turnIndex = findTurnIndex(model, action.turnId);
      if (turnIndex < 0) return model;
      return withTurn(model, turnIndex, { ...model.turns[turnIndex], folded: action.folded });
    }
    case "reset":
      return resetConversation(model, index);
    default:
      return model;
  }
}

export function replayLines(lines: ProtocolLine[], nowMs = Date.now()): TranscriptModel {
  const index = makeIndex();
  let model = createModel();
  for (const line of lines) model = applyLine(model, index, line, nowMs);
  return model;
}

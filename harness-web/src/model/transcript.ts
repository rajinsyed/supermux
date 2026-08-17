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
import { insertBlock, locateTool, markTurnAborted, settleTurn } from "./blocks";
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
import type {
  LocalAction,
  PendingPermission,
  ToolBlock,
  TranscriptModel,
  Turn
} from "./types";

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
        startFailed: undefined,
        revision: model.revision + 1
      };
    case "runExited": {
      const closed = closeOpenTurns(model, nowMs, event.status === 0 ? "complete" : "error");
      return {
        ...closed,
        runPhase: "exited",
        exitError: event.error,
        startFailed: undefined,
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
  // `result` is the only end-of-turn signal the CLI reliably emits: the live
  // probes (ctl/perm/plan/int logs) and the 202-line reference trace contain
  // ZERO `session_state_changed` frames. Treating that frame as the sole writer
  // of `sessionState` latched the pane to "running" forever after the first
  // turn — Stop button up, composer queueing, queue never draining. So the
  // result settles the flag too, unless a `can_use_tool` is still outstanding,
  // in which case the turn genuinely waits on the user. A CLI that does emit
  // `session_state_changed` still overrides this (systemLines.ts).
  const sessionState = model.pending.length === 0 ? "idle" : model.activity.sessionState;
  const next: TranscriptModel = {
    ...model,
    usage,
    activity: { ...model.activity, sessionState, status: null, thinkingTokens: 0 },
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

/**
 * An AskUserQuestion arrives ONLY as a `can_use_tool` control request — unlike
 * Bash or ExitPlanMode, no `assistant` frame ever announces it — so answering it
 * used to erase the exchange entirely: neither the question, nor the options,
 * nor the choice survived anywhere in the transcript. Scrolling back to see what
 * you were asked and what you picked is ordinary. On resolution the request is
 * therefore materialised as a settled interactive block carrying both the
 * original input and the submitted answers, which `InteractiveBody` renders.
 *
 * Scoped to the interactive tools and guarded on the id not already being on
 * screen, so an ordinary Bash or Edit approval — which does have its own
 * streamed block — is never duplicated here.
 */
function recordAnsweredRequest(
  model: TranscriptModel,
  index: TranscriptIndex,
  resolved: PendingPermission,
  action: Extract<LocalAction, { kind: "permissionResolved" }>,
  nowMs: number
): TranscriptModel {
  const toolUseId = resolved.request.tool_use_id;
  if (resolved.kind !== "question") return model;
  if (!toolUseId || locateTool(model, index, toolUseId)) return model;
  const turnIndex = model.turns.length - 1;
  if (turnIndex < 0) return model;
  const denied = action.behavior === "deny";
  const input = (denied ? resolved.request.input : action.updatedInput ?? resolved.request.input) as JsonObject;
  const block: ToolBlock = {
    kind: "tool",
    key: `answered:${resolved.requestId}`,
    messageId: `answered:${resolved.requestId}`,
    toolUseId,
    name: resolved.request.tool_name,
    input,
    inputComplete: true,
    status: denied ? "denied" : "success",
    streaming: false,
    startedAtMs: resolved.receivedAtMs,
    endedAtMs: nowMs,
    children: []
  };
  return insertBlock(model, index, turnIndex, block).model;
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
    case "permissionResolved": {
      const resolved = model.pending.find((p) => p.requestId === action.requestId);
      const next: TranscriptModel = {
        ...model,
        pending: model.pending.filter((p) => p.requestId !== action.requestId),
        revision: model.revision + 1
      };
      if (!resolved) return next;
      return recordAnsweredRequest(next, index, resolved, action, nowMs);
    }
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
    case "startFailed":
      return {
        ...closeOpenTurns(model, nowMs, "error"),
        runPhase: "exited",
        exitError: action.error,
        startFailed: true,
        activity: { ...model.activity, sessionState: "idle", status: null },
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

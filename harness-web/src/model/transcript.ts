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
import { appendPendingRelay, hydrateThread, isThreadRunning } from "./agentThreads";
import { insertBlock, markTurnAborted, readTool, settleTurn, writeBlock } from "./blocks";
import {
  activeTurnIndex,
  adoptSessionModel,
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
import { hasLiveBackgroundWork, isTaskSettled } from "./tasks";
import {
  clearRetryBanners,
  closeOpenTurns,
  createModel,
  resetConversation,
  startUserTurn,
  truncateBeforeUserMessage
} from "./turns";
import type {
  AgentThread,
  Block,
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
    case "runStarted": {
      // No turn can still be live at the instant a process starts: the run that
      // was producing it is gone. A turn left open here comes from replayed
      // history whose recording stops mid-turn — a session that crashed while
      // Claude was working is exactly that — and it stays "streaming" forever,
      // so `ensureTurn` hands the NEW run's output to it and the transcript
      // files the next answer under the previous prompt.
      const settled = closeOpenTurns(model, nowMs, "error");
      return {
        ...settled,
        runPhase: "running",
        runId: event.runId,
        exitError: undefined,
        startFailed: undefined,
        // Same reasoning for the activity flags: "running"/"compacting" read off
        // replayed history describes work the dead process was doing. Carried
        // into the new run they make a fresh pane claim to be thinking, and a
        // send sits queued behind activity that will never end on its own.
        activity: { ...settled.activity, sessionState: "idle", status: null, thinkingTokens: 0 },
        // Background tasks belong to the PROCESS, not the conversation: the SDK
        // scopes both the set and its ids per process, and it re-sends the whole
        // set on (re)start. Carried across a restart the strip would offer Stop
        // and View on shells that died with the old process, against task ids the
        // new one has never heard of.
        backgroundTasks: [],
        tasksById: {},
        // Threads SURVIVE a restart — a resumed session's agents are still worth
        // reading — but none of them is still running: the process that was
        // producing their frames is gone. Left "running" they would spin a
        // status dot and a live elapsed timer forever, on a dock row for work
        // that ended when the run did.
        agentThreads: settleLiveThreads(settled.agentThreads, nowMs),
        revision: settled.revision + 1
      };
    }
    case "runExited": {
      const closed = closeOpenTurns(model, nowMs, event.status === 0 ? "complete" : "error");
      return {
        ...closed,
        runPhase: "exited",
        exitError: event.error,
        startFailed: undefined,
        activity: { ...closed.activity, sessionState: "idle", status: null },
        pending: [],
        // The queue lived inside the process that just died: those messages were
        // handed to a CLI that will never answer them. Left in `queued` they are
        // not merely stale chips — `ensureTurn` promotes queued[0] onto the first
        // frame of the NEXT run, so a later message renders under an earlier
        // message's text and the transcript attributes the wrong prompt to the
        // wrong answer. They are not discarded either: the user typed them, so
        // they move aside for the hook to re-send, in order, once a run is up.
        queued: [],
        stranded: closed.stranded.concat(closed.queued),
        revision: closed.revision + 1
      };
    }
    case "stderr":
      return { ...model, stderrTail: model.stderrTail.concat(event.text).slice(-40) };
    case "modelCatalog":
      return { ...model, cachedModels: event.models, revision: model.revision + 1 };
    case "sessionTitle":
      // The CLI's own topic title. The native side only emits this while the
      // user has not renamed the session, and the CLI retitles as the topic
      // evolves, so the latest event always wins here.
      return { ...model, session: { ...model.session, title: event.title }, revision: model.revision + 1 };
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

/**
 * Every still-running thread, marked finished at `nowMs`.
 *
 * Used at the process boundary only. A thread's status normally comes off the
 * wire; a run that dies stops sending, so nothing would ever move these — and a
 * dock row with a spinning dot and an elapsed counter climbing past the process
 * that owned it is the same lie the tasks strip already refuses to tell.
 */
function settleLiveThreads(
  threads: Record<string, AgentThread>,
  nowMs: number
): Record<string, AgentThread> {
  let changed = false;
  const out: Record<string, AgentThread> = {};
  for (const [id, thread] of Object.entries(threads)) {
    if (!isThreadRunning(thread)) {
      out[id] = thread;
      continue;
    }
    changed = true;
    out[id] = {
      ...thread,
      status: "stopped",
      // The thread ended when it last PRODUCED something, not when this
      // boundary happens to run — a replayed thread settles days after its
      // frames were written, and wall-now would report a nonsense span
      // ("Worked for 2d"). The last tool timestamp is the best record; the
      // thread's own start is the fallback (near-now for a live crash,
      // historical for a replay — honest either way).
      endedAtMs: thread.endedAtMs ?? lastThreadFrameAtMs(thread) ?? thread.startedAtMs,
      revision: thread.revision + 1
    };
  }
  return changed ? out : threads;
}

/** The latest timestamp any of the thread's own blocks carries. */
function lastThreadFrameAtMs(thread: AgentThread): number | undefined {
  let latest: number | undefined;
  const walk = (blocks: Block[]) => {
    for (const block of blocks) {
      if (block.kind === "tool") {
        const at = block.endedAtMs ?? block.startedAtMs;
        if (at !== undefined && (latest === undefined || at > latest)) latest = at;
        walk(block.children);
      }
    }
  };
  walk(thread.blocks);
  return latest;
}

/**
 * Every unsettled task record, latched terminal — the same boundary as
 * {@link settleLiveThreads}, for the records that feed the tasks strip and the
 * workflow rows. `stopped` is the honest verdict: the process that owned them
 * is gone, and the status latch in systemLines refuses to reopen a terminal
 * record, so a stale late frame cannot revive one either.
 */
function settleLiveTaskRecords(
  tasksById: TranscriptModel["tasksById"],
  nowMs: number
): TranscriptModel["tasksById"] {
  let changed = false;
  const out: TranscriptModel["tasksById"] = {};
  for (const [id, record] of Object.entries(tasksById)) {
    if (isTaskSettled(record.status)) {
      out[id] = record;
      continue;
    }
    changed = true;
    out[id] = {
      ...record,
      status: "stopped",
      endedAtMs: record.endedAtMs ?? nowMs
    };
  }
  return changed ? out : tasksById;
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
  // The turn is over, so any "retrying attempt 1 of 3" banner it raised has
  // stopped being news. It clears itself rather than waiting to be closed.
  let next: TranscriptModel = {
    ...clearRetryBanners(model),
    usage,
    activity: { ...model.activity, sessionState, status: null, thinkingTokens: 0 },
    revision: model.revision + 1
  };
  if (turnIndex < 0) return next;
  const turn = next.turns[turnIndex];
  // The turn that carried a relay has answered — main ran SendMessage and said
  // RELAYED. That is not the same as the agent having the message (it reads its
  // mailbox at its next tool round), so the record advances one step, not two.
  const relay = turn.userUuid ? next.relays[turn.userUuid] : undefined;
  if (relay && relay.state === "sending") {
    // A turn that errored or was interrupted never ran SendMessage, so the
    // message did not go anywhere. Reporting that as "passed to the agent"
    // would be the one relay lie that matters.
    const failed = aborted || line.is_error === true;
    next = {
      ...next,
      relays: {
        ...next.relays,
        [relay.uuid]: { ...relay, state: failed ? "failed" : "relayed" }
      }
    };
  }
  const settled = aborted ? markTurnAborted(turn, nowMs) : settleTurn(turn, nowMs);
  const state: Turn["state"] = aborted ? "aborted" : line.is_error ? "error" : "complete";
  const live = hasLiveBackgroundWork(settled);
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
    // A completed turn folds — EXCEPT one that launched work still running in
    // the background. A workflow's `result` arrives the instant it is launched
    // and its agents run for another ten seconds; folding on that frame made the
    // live progress card the user was watching disappear mid-flight, leaving the
    // pane claiming the turn was over while three agents were still going. The
    // fold is deferred, not cancelled: systemLines applies it when the task
    // reaches its terminal edge.
    // The user's own fold choice outranks the automatic one in both directions.
    folded:
      settled.foldOverride !== undefined
        ? settled.foldOverride
        : state === "complete" && !live,
    foldWhenTasksSettle:
      settled.foldOverride === undefined && state === "complete" && live ? true : undefined
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
 * The transcript's record of an answered question, in BOTH the shapes the CLI
 * ships it.
 *
 * Older CLIs raised AskUserQuestion ONLY as a `can_use_tool` control request —
 * no `assistant` frame announced it — so answering it erased the exchange
 * entirely, and resolution materialises a settled interactive block carrying
 * the input and the submitted answers. The CURRENT CLI (2.1.23x traces) DOES
 * stream an assistant `tool_use` frame first, so the card is usually already on
 * screen when the user submits; for that shape the submitted answers are merged
 * into the existing block's input instead — the round-6 screenshot ("Asked you
 * a question" expanded to em-dashes) was this path silently skipping, leaving
 * the answers to exist nowhere until the CLI's tool_result echoed them back.
 *
 * Still scoped to questions: an ordinary Bash or Edit approval's streamed block
 * needs neither a duplicate card nor an input merge (its `updatedInput` is the
 * unmodified request input, and its real outcome arrives in the tool_result).
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
  if (!toolUseId) return model;
  // The current CLI DOES stream an assistant tool_use frame for
  // AskUserQuestion (the round-6 trace has one), so the card is often already
  // on screen when the user submits. Skipping entirely here — the old guard —
  // dropped the submitted answers on the floor: the block's input held the
  // questions alone, and the settled card showed "—" for every answer until
  // (and unless) the CLI's tool_result echoed them back. The answers exist
  // only in this action's payload at this moment, so they are merged into the
  // block the user is looking at.
  const existing = readTool(model, index, toolUseId);
  if (existing) {
    if (action.behavior === "deny" || !action.updatedInput) return model;
    return writeBlock(model, existing.location, {
      ...existing.block,
      input: { ...existing.block.input, ...action.updatedInput }
    });
  }
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
      // A relay is recorded BEFORE the turn or the chip, so both surfaces know
      // from the first frame that this message is addressed to an agent: the
      // main transcript renders it as a "→ sent to X" chip rather than a bubble
      // the user never wrote, and the agent view shows the text as pending.
      let next = model;
      if (action.relay) {
        next = {
          ...model,
          relays: {
            ...model.relays,
            [action.uuid]: {
              uuid: action.uuid,
              toolUseId: action.relay.toolUseId,
              description: action.relay.description,
              text: action.text,
              sentAtMs: action.atMs,
              state: "sending",
              backgrounded: action.backgrounded
            }
          }
        };
        next = appendPendingRelay(next, action.relay.toolUseId, action.uuid, action.text, nowMs);
      }
      // A non-empty queue is itself a busy signal. Without that clause a message
      // typed in the gap between one `result` and the next turn's first frame —
      // where sessionState is already `idle` and no turn is open — skipped the
      // queue and opened its own turn, so it rendered and answered AHEAD of
      // chips that had been waiting longer. The queue is FIFO or it is nothing.
      const busy =
        next.queued.length > 0 ||
        next.activity.sessionState !== "idle" ||
        activeTurnIndex(next) >= 0;
      if (busy) {
        return {
          ...next,
          queued: next.queued.concat({
            uuid: action.uuid,
            text: action.text,
            images: action.images,
            queuedAtMs: action.atMs,
            relay: action.relay
          }),
          revision: next.revision + 1
        };
      }
      return startUserTurn(next, index, action.text, action.images, action.atMs, action.uuid);
    }
    case "hydrateThread": {
      const thread = model.agentThreads[action.toolUseId];
      // Live frames always win. A disk replay is the FALLBACK for a thread that
      // never received any — a resumed session, a forwarding gap — and folding
      // it into a thread that has live blocks would draw every message twice.
      if (!thread || thread.hasLiveFrames || thread.hydratedFromDisk) return model;
      return hydrateThreadFromDisk(model, action.toolUseId, action.events, nowMs);
    }
    case "cancelQueued":
      return {
        ...model,
        queued: model.queued.filter((q) => q.uuid !== action.uuid),
        // A chip the user dismisses is dismissed whichever list it is sitting in;
        // otherwise cancelling a stranded message would re-send it anyway.
        stranded: model.stranded.filter((q) => q.uuid !== action.uuid),
        revision: model.revision + 1
      };
    // An interrupt that cancels the queue drops them on the CLI side, so the
    // chips have to go too: a queue that only LOOKS full now blocks every later
    // send from opening a turn, and the pane would sit "queued" forever.
    case "clearQueued":
      return model.queued.length === 0 && model.stranded.length === 0
        ? model
        : { ...model, queued: [], stranded: [], revision: model.revision + 1 };
    case "takeStranded":
      return model.stranded.length === 0
        ? model
        : { ...model, stranded: [], revision: model.revision + 1 };
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
        session: {
          ...model.session,
          model: action.model,
          effort: action.effort,
          // A user PICK latches until the wire confirms it, so a frame from
          // the model the process is still on cannot revert the menu (see
          // SessionMeta.modelPickPending). A bootstrap projection does not: a
          // restore snapshot is a memory, and the live wire outranks it.
          modelPickPending: action.pick ? true : model.session.modelPickPending
        },
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
        // Nothing ever received these: the process never came up. Same reason as
        // `runExited` — a surviving queue is promoted onto a later run's turns —
        // and the same remedy: held for re-send rather than thrown away.
        queued: [],
        stranded: model.stranded.concat(model.queued),
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
      return withTurn(model, turnIndex, {
        ...model.turns[turnIndex],
        folded: action.folded,
        // A deliberate open or close retires the pending auto-fold: a turn the
        // user has just opened must not collapse under them the moment its
        // background work happens to finish. The override is remembered so a
        // reopen (the CLI's summary leg merging back into this turn) and the
        // merged turn's own later result defer to it too.
        foldWhenTasksSettle: undefined,
        foldOverride: action.folded
      });
    }
    case "truncateBeforeUserMessage":
      return truncateBeforeUserMessage(model, index, action.uuid);
    case "cachedModels":
      return { ...model, cachedModels: action.models, revision: model.revision + 1 };
    case "sessionDefaults":
      // A property of the BINARY'S SETTINGS, not of this conversation, held on
      // the session because that is what every display site already resolves
      // from. It never overwrites a real selection: resolveModel and
      // effectiveEffort consult these only when nothing stronger exists.
      if (
        model.session.defaultModel === action.model &&
        model.session.defaultEffort === action.effort
      ) {
        return model;
      }
      return {
        ...model,
        session: { ...model.session, defaultModel: action.model, defaultEffort: action.effort },
        revision: model.revision + 1
      };
    case "historyTruncated":
      return { ...model, historyTruncated: true, revision: model.revision + 1 };
    case "historyReplayed": {
      // Replayed history carries no `result` frames, so its final turn is still
      // "streaming" when the drain finishes — and the `runStarted` that follows
      // a resume would close it as an ERROR ("Failed after …") for the crime of
      // being history. Closed here as complete instead, at each turn's own last
      // frame. A turn the transcript recorded as interrupted stays aborted:
      // closeOpenTurns only touches streaming turns.
      let next = closeOpenTurns(model, nowMs, "complete");
      if (next !== model) {
        next = {
          ...next,
          activity: { ...next.activity, sessionState: "idle", status: null, thinkingTokens: 0 }
        };
      }
      // Replayed history is by definition NOT running, and turns are not the
      // only thing the replay leaves live. Task tool_use records spawn agent
      // threads born "running", and disk history carries no task frames to
      // ever settle them — so an auto-restored session put every subagent it
      // had ever spawned on the dock as "Working" (12 orbit grids animating
      // for a session where nothing ran). The restore-bootstrap replay never
      // emits `runStarted` (no process starts), so the boundary that settles
      // threads there has to be applied here too. Same for task records and
      // the background strip: an explicit resume's `runStarted` clears them
      // moments later anyway, but the bootstrap replay has no later boundary.
      next = {
        ...next,
        agentThreads: settleLiveThreads(next.agentThreads, nowMs),
        tasksById: settleLiveTaskRecords(next.tasksById, nowMs),
        backgroundTasks: [],
        revision: next.revision + 1
      };
      // History also carries no init frame (the native mapper forwards only
      // user/assistant records), so the pane's model selection would otherwise
      // be whatever it held BEFORE the resume — the previous session's model,
      // or nothing. The resumed session's own last assistant frame is the one
      // record of what it was actually running, so the trigger adopts it here,
      // and startOptions carries it onto the restart so the CLI does not fall
      // back to the settings default and silently switch the session's model.
      //
      // UNLESS an unconfirmed user pick is pending: the restore-bootstrap
      // replay lands seconds late on a big session file, and what it records
      // is by definition OLDER than a pick made while it was loading. Both
      // adoptions — model and effort — describe that old session, so both
      // defer to the pick (adoptSessionModel enforces the model half; the
      // effort half is guarded here for the same reason).
      const pickPending = next.session.modelPickPending === true;
      if (
        !pickPending &&
        next.lastAssistantModel &&
        next.lastAssistantModel !== next.session.model
      ) {
        next = {
          ...(next === model ? { ...next } : next),
          session: adoptSessionModel(next.session, next.cachedModels, next.lastAssistantModel),
          revision: next.revision + 1
        };
      }
      // The records stamp effort too ("effort":"xhigh" on every assistant
      // line), and it is adopted for the same reason as the model: the resumed
      // session was RUNNING at that level, so the trigger must say so and the
      // restart must carry it rather than silently dropping to a default.
      // After adoptSessionModel, so a model change's deliberate effort drop is
      // immediately refilled with the resumed session's own recorded level.
      if (
        !pickPending &&
        next.lastAssistantEffort &&
        next.lastAssistantEffort !== next.session.effort
      ) {
        next = {
          ...next,
          session: { ...next.session, effort: next.lastAssistantEffort },
          revision: next.revision + 1
        };
      }
      return next;
    }
    case "reset":
      return resetConversation(model, index, {
        preserveModelPick: action.preserveModelPick
      });
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

/**
 * The disk fallback for an agent view whose thread never received live frames.
 *
 * The agent's own session file is replayed through an ISOLATED reducer — its
 * frames carry the same tool_use ids and turn uuids as the live session, and
 * folding them into the pane's model would file a subagent's Bash card under
 * the turn that spawned it. The blocks that come out are the same `Block` union
 * the live path builds, so the agent view renders both identically; only the
 * prompt is lifted, because a replayed session records it as a turn's user text
 * rather than as a thread block.
 */
export function threadBlocksFromLines(lines: ProtocolLine[], nowMs = Date.now()): Block[] {
  const replayed = replayLines(lines, nowMs);
  const out: Block[] = [];
  for (const turn of replayed.turns) {
    if (turn.userText) {
      out.push({
        kind: "userText",
        key: `${turn.id}:prompt`,
        text: turn.userText,
        prompt: out.length === 0
      });
    }
    for (const block of turn.blocks) out.push(block);
  }
  return out;
}

function hydrateThreadFromDisk(
  model: TranscriptModel,
  toolUseId: string,
  events: ProtocolLine[],
  nowMs: number
): TranscriptModel {
  return hydrateThread(model, toolUseId, threadBlocksFromLines(events, nowMs), nowMs);
}

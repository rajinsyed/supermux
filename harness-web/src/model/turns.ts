import { settleTurn } from "./blocks";
import {
  activeTurnIndex,
  deriveTitle,
  emptySession,
  emptyUsage,
  findTurnIndex,
  withTurn,
  type TranscriptIndex
} from "./helpers";
import type {
  Block,
  ImageAttachment,
  NoticeErrorKind,
  RelayRecord,
  TranscriptModel,
  Turn
} from "./types";

export function createModel(): TranscriptModel {
  return {
    generation: 0,
    session: emptySession(),
    turns: [],
    pending: [],
    queued: [],
    stranded: [],
    todos: [],
    usage: emptyUsage(),
    activity: { sessionState: "idle", status: null, thinkingTokens: 0 },
    banners: [],
    backgroundTasks: [],
    tasksById: {},
    agentThreads: {},
    agentRootIds: [],
    relays: {},
    runPhase: "idle",
    stderrTail: [],
    revision: 0
  };
}

export function nextBlockKey(index: TranscriptIndex, messageId: string): string {
  index.blockCounter += 1;
  return `${messageId}!${index.blockCounter}`;
}

export function startUserTurn(
  model: TranscriptModel,
  index: TranscriptIndex,
  text: string,
  images: ImageAttachment[] | undefined,
  atMs: number,
  uuid?: string
): TranscriptModel {
  const closed = closeOpenTurns(model, atMs, "complete");
  index.nextSeq += 1;
  const turn: Turn = {
    id: uuid ?? `turn:${closed.generation}:${index.nextSeq}`,
    seq: index.nextSeq,
    userText: text,
    userImages: images,
    userUuid: uuid,
    startedAtMs: atMs,
    state: "streaming",
    blocks: [],
    folded: false,
    revision: 0
  };
  const session = closed.session.title ? closed.session : { ...closed.session, title: deriveTitle(text) };
  return { ...closed, session, turns: closed.turns.concat(turn), revision: closed.revision + 1 };
}

export function ensureTurn(
  model: TranscriptModel,
  index: TranscriptIndex,
  atMs: number,
  parent: string | null
): { model: TranscriptModel; turnIndex: number; turnId: string } {
  if (parent) {
    const location = index.toolLocations.get(parent);
    if (location) {
      const turnIndex = findTurnIndex(model, location.turnId);
      if (turnIndex >= 0) return { model, turnIndex, turnId: location.turnId };
    }
  }
  const existing = activeTurnIndex(model);
  if (existing >= 0) return { model, turnIndex: existing, turnId: model.turns[existing].id };
  const promoted = model.queued[0];
  let next = model;
  if (promoted) {
    next = { ...model, queued: model.queued.slice(1) };
    next = startUserTurn(next, index, promoted.text, promoted.images, atMs, promoted.uuid);
  } else {
    index.nextSeq += 1;
    const turn: Turn = {
      id: `turn:${model.generation}:${index.nextSeq}`,
      seq: index.nextSeq,
      startedAtMs: atMs,
      state: "streaming",
      blocks: [],
      folded: false,
      revision: 0
    };
    next = { ...model, turns: model.turns.concat(turn), revision: model.revision + 1 };
  }
  const turnIndex = next.turns.length - 1;
  return { model: next, turnIndex, turnId: next.turns[turnIndex].id };
}

export function closeOpenTurns(
  model: TranscriptModel,
  atMs: number,
  state: "complete" | "error"
): TranscriptModel {
  let changed = false;
  const turns = model.turns.map((turn) => {
    if (turn.state !== "streaming") return turn;
    changed = true;
    return { ...settleTurn(turn, atMs), state, folded: state === "complete" };
  });
  return changed ? { ...model, turns, revision: model.revision + 1 } : model;
}

export function resetConversation(model: TranscriptModel, index: TranscriptIndex): TranscriptModel {
  index.seenUuids.clear();
  index.toolLocations.clear();
  index.taskToTool.clear();
  index.finalizedBlocks.clear();
  index.streamBlockKeys.clear();
  index.streamMessageIds.clear();
  index.nextSeq = 0;
  index.blockCounter = 0;
  return {
    ...createModel(),
    generation: model.generation + 1,
    // A cleared pane is on NO session. Carrying the old id forward is what made
    // "New session" resume the very conversation it had just discarded: the id
    // is the pane's session identity, and every resume path reads it.
    session: { ...model.session, title: undefined, sessionId: undefined },
    runPhase: model.runPhase,
    runId: model.runId,
    // A property of the BINARY, not of the conversation: clearing it here would
    // empty the model menu on every "New session".
    cachedModels: model.cachedModels,
    // Not part of the conversation either: these are messages the user typed
    // that no process ever answered. A reset replaces the transcript, and
    // dropping them here would silently delete typed text at exactly the moment
    // — a Restart after a crash — when the user most expects it to survive.
    // Cancelling a chip, or an interrupt-with-cancel, is how they are discarded.
    stranded: model.stranded,
    revision: model.revision + 1
  };
}

/**
 * Drop the turn that carries `uuid` and every turn after it — the transcript
 * shape `--resume-session-at=<previous uuid>` produces on the CLI side. The
 * local model has to move first: the restarted process replays nothing until
 * its first frame, and leaving the dropped turns on screen in the meantime
 * shows a conversation the session no longer has.
 */
export function truncateBeforeUserMessage(
  model: TranscriptModel,
  index: TranscriptIndex,
  uuid: string
): TranscriptModel {
  const cut = model.turns.findIndex((turn) => turn.userUuid === uuid);
  if (cut < 0) return model;
  const turns = model.turns.slice(0, cut);
  const kept = new Set(turns.map((turn) => turn.id));
  for (const [toolUseId, location] of index.toolLocations) {
    if (!kept.has(location.turnId)) index.toolLocations.delete(toolUseId);
  }
  // A relay is remembered so the MAIN transcript can draw its user message as a
  // chip instead of a bubble. Once that turn is gone the record describes
  // nothing on screen, and keeping it would compact a LATER message that
  // happened to reuse the uuid.
  const relays: Record<string, RelayRecord> = {};
  for (const [uuid, relay] of Object.entries(model.relays)) {
    if (kept.has(uuid)) relays[uuid] = relay;
  }
  return {
    ...model,
    turns,
    relays,
    // Everything below described the dropped turns: an approval prompt for a
    // tool call that no longer exists cannot be answered, and a queued message
    // was typed against a conversation that is being rewritten.
    pending: [],
    queued: [],
    stranded: [],
    todos: [],
    activity: { sessionState: "idle", status: null, thinkingTokens: 0 },
    revision: model.revision + 1
  };
}

export function pushBanner(
  model: TranscriptModel,
  severity: "info" | "warning" | "error",
  title: string,
  detail: string | undefined,
  nowMs: number,
  /** A catalog key that phrases `title`, when the reducer knows the outcome. */
  titleKey?: string
): TranscriptModel {
  const banner = {
    id: `banner:${nowMs}:${model.revision}:${model.banners.length}`,
    severity,
    title,
    detail,
    titleKey,
    createdAtMs: nowMs
  };
  return { ...model, banners: model.banners.concat(banner).slice(-5), revision: model.revision + 1 };
}

export function appendNotice(
  model: TranscriptModel,
  level: "info" | "warning" | "error",
  text: string,
  key: string,
  turnIndex?: number,
  errorKind?: NoticeErrorKind
): TranscriptModel {
  const target = turnIndex ?? model.turns.length - 1;
  if (target < 0) return model;
  const turn = model.turns[target];
  const notice: Block = { kind: "notice", key, level, text, errorKind };
  return withTurn(model, target, {
    ...turn,
    blocks: turn.blocks.concat(notice),
    revision: turn.revision + 1
  });
}

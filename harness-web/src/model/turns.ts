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
import type { Block, ImageAttachment, TranscriptModel, Turn } from "./types";

export function createModel(): TranscriptModel {
  return {
    generation: 0,
    session: emptySession(),
    turns: [],
    pending: [],
    queued: [],
    todos: [],
    usage: emptyUsage(),
    activity: { sessionState: "idle", status: null, thinkingTokens: 0 },
    banners: [],
    backgroundTasks: [],
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
    session: { ...model.session, title: undefined },
    runPhase: model.runPhase,
    runId: model.runId,
    revision: model.revision + 1
  };
}

export function pushBanner(
  model: TranscriptModel,
  severity: "info" | "warning" | "error",
  title: string,
  detail: string | undefined,
  nowMs: number
): TranscriptModel {
  const banner = {
    id: `banner:${nowMs}:${model.revision}:${model.banners.length}`,
    severity,
    title,
    detail,
    createdAtMs: nowMs
  };
  return { ...model, banners: model.banners.concat(banner).slice(-5), revision: model.revision + 1 };
}

export function appendNotice(
  model: TranscriptModel,
  level: "info" | "warning" | "error",
  text: string,
  key: string,
  turnIndex?: number
): TranscriptModel {
  const target = turnIndex ?? model.turns.length - 1;
  if (target < 0) return model;
  const turn = model.turns[target];
  const notice: Block = { kind: "notice", key, level, text };
  return withTurn(model, target, {
    ...turn,
    blocks: turn.blocks.concat(notice),
    revision: turn.revision + 1
  });
}

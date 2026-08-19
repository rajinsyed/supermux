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
    lastFrameAtMs: atMs,
    state: "streaming",
    blocks: [],
    folded: false,
    revision: 0
  };
  const session = closed.session.title ? closed.session : { ...closed.session, title: deriveTitle(text) };
  return { ...closed, session, turns: closed.turns.concat(turn), revision: closed.revision + 1 };
}

/**
 * A LOCAL slash command (`/model opus[1m]`), reconstructed from the transcript's
 * `<command-name>/<command-args>` record. It is born COMPLETE: a local command
 * runs inside the CLI and no `result` frame will ever settle it, so a streaming
 * command turn would spin "Working…" forever. It also never titles the session —
 * "/model" is not a topic.
 */
export function startCommandTurn(
  model: TranscriptModel,
  index: TranscriptIndex,
  name: string,
  args: string | undefined,
  atMs: number,
  uuid?: string
): TranscriptModel {
  const closed = closeOpenTurns(model, atMs, "complete");
  index.nextSeq += 1;
  const turn: Turn = {
    id: uuid ?? `turn:${closed.generation}:${index.nextSeq}`,
    seq: index.nextSeq,
    command: { name, args },
    userUuid: uuid,
    startedAtMs: atMs,
    lastFrameAtMs: atMs,
    endedAtMs: atMs,
    state: "complete",
    blocks: [],
    folded: false,
    revision: 0
  };
  return { ...closed, turns: closed.turns.concat(turn), revision: closed.revision + 1 };
}

/**
 * The compact-summary continuation preamble ("This session is being continued
 * from a previous conversation…"). The summary text is machine-written context
 * for the MODEL, not something the user said — rendering it as a giant user
 * bubble is the bug. It becomes a quiet divider, and the turn stays streaming
 * because the assistant's continuation frames follow it and belong to it.
 */
export function startContinuationTurn(
  model: TranscriptModel,
  index: TranscriptIndex,
  atMs: number,
  uuid?: string
): TranscriptModel {
  const closed = closeOpenTurns(model, atMs, "complete");
  index.nextSeq += 1;
  const divider: Block = {
    kind: "divider",
    key: `continued:${uuid ?? index.nextSeq}`,
    variant: "continued"
  };
  const turn: Turn = {
    id: uuid ?? `turn:${closed.generation}:${index.nextSeq}`,
    seq: index.nextSeq,
    userUuid: uuid,
    startedAtMs: atMs,
    lastFrameAtMs: atMs,
    state: "streaming",
    blocks: [divider],
    folded: false,
    revision: 0
  };
  return { ...closed, turns: closed.turns.concat(turn), revision: closed.revision + 1 };
}

/**
 * A local command's output, appended to the turn it belongs to — the command
 * chip immediately above it. Never opens or reopens a turn: `<local-command-
 * stdout>` follows its command record, and routing it through `ensureTurn`
 * would reopen a completed turn and leave it streaming forever.
 */
export function appendCommandOutput(
  model: TranscriptModel,
  text: string,
  key: string,
  atMs: number
): TranscriptModel {
  const target = model.turns.length - 1;
  if (target < 0) return model;
  const turn = model.turns[target];
  const block: Block = { kind: "commandOutput", key, text };
  return withTurn(model, target, {
    ...turn,
    blocks: turn.blocks.concat(block),
    lastFrameAtMs: atMs,
    revision: turn.revision + 1
  });
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
    // Output arriving with NO user message since the last turn settled belongs
    // to THAT turn, not to a new one. A workflow's `result` lands the instant it
    // is launched and the CLI then opens its own summary leg (init/status/
    // message_start, no user frame); filing that leg as a fresh turn gave one
    // prompt two "Worked for" folds. The turn REOPENS: its result is cleared so
    // the next `result` frame settles it again (a turn that already carries one
    // is invisible to `unresolvedTurnIndex`), and the fold retires because the
    // turn is visibly working again. Only a cleanly completed turn is reopened —
    // an error or an abort is a boundary the user saw, and new output after it
    // reads as a new attempt.
    const lastIndex = model.turns.length - 1;
    const last = model.turns[lastIndex];
    // A COMMAND turn never reopens: it is a `/model` chip, born complete, and
    // assistant output arriving after it belongs to a new turn — filing the
    // model's next answer under a slash-command chip misattributes both.
    if (last && last.state === "complete" && !last.command) {
      const reopened: Turn = {
        ...last,
        state: "streaming",
        endedAtMs: undefined,
        result: undefined,
        // A streaming turn never renders folded; the user's own foldOverride
        // rides through the spread and settles the question again at the next
        // result.
        folded: false,
        foldWhenTasksSettle: undefined,
        revision: last.revision + 1
      };
      return {
        model: withTurn(model, lastIndex, reopened),
        turnIndex: lastIndex,
        turnId: reopened.id
      };
    }
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
    // The turn ends when it last PRODUCED something, not when this boundary
    // happens to run. Replayed history is closed at a process boundary days
    // after its frames were written, and a live turn closed by a crash stopped
    // at its last output; either way `atMs` here would report a span the work
    // never had ("Worked for 2d" on a replayed session was exactly that).
    const endAt = turn.lastFrameAtMs ?? atMs;
    return {
      ...settleTurn(turn, endAt),
      state,
      folded: turn.foldOverride !== undefined ? turn.foldOverride : state === "complete"
    };
  });
  return changed ? { ...model, turns, revision: model.revision + 1 } : model;
}

export function resetConversation(
  model: TranscriptModel,
  index: TranscriptIndex,
  options?: { preserveModelPick?: boolean }
): TranscriptModel {
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
    // The pending-pick latch NORMALLY clears with it: a plain reset precedes
    // either a restart whose params carry the pick (New Session — the init
    // frame then confirms it) or a deliberate move onto another session whose
    // own model must win (an explicit resume). A latch surviving into a resume
    // would make historyReplayed ignore the resumed session's recorded model.
    // The one exception is the RESTORE-bootstrap replay (`preserveModelPick`):
    // that reset replays the pane's own serialized session, often seconds
    // late, and a pick the user made in the meantime is newer than everything
    // the replay carries — clearing the latch there let the late replay adopt
    // the OLD session's model over the user's fresh choice.
    session: {
      ...model.session,
      title: undefined,
      sessionId: undefined,
      modelPickPending: options?.preserveModelPick ? model.session.modelPickPending : undefined
    },
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

/**
 * Retire the "retrying…" banners once the turn they were about has ended.
 *
 * An `api_retry` banner is a live report of a request in trouble, and it earns
 * its place while that is true. Once the turn resolves — the retry worked, or
 * it failed and the turn carries the error itself — the banner is a stale chip
 * the user has to close by hand, which is exactly the class of thing being
 * removed. Only the retry banners go: a hard failure raised beside them is not
 * made untrue by the next turn ending.
 */
export function clearRetryBanners(model: TranscriptModel): TranscriptModel {
  if (!model.banners.some((banner) => banner.retry !== undefined)) return model;
  return {
    ...model,
    banners: model.banners.filter((banner) => banner.retry === undefined),
    revision: model.revision + 1
  };
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

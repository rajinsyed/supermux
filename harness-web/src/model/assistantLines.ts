import type { AssistantLine, ContentBlock, JsonObject } from "../protocol/types";
import { applyAssistantToThread, registerRootSpawns } from "./agentThreads";
import {
  evictUuids,
  findOpenBlock,
  insertBlock,
  markTurnAborted,
  mergeTextBlock,
  mergeThinkingBlock,
  mergeToolUseBlock,
  readTool,
  settleTurn,
  writeBlock
} from "./blocks";
import { asString, blockAtPath, findTurnIndex, withTurn, type TranscriptIndex } from "./helpers";
import { appendNotice, ensureTurn, nextBlockKey } from "./turns";
import type {
  Block,
  NoticeErrorKind,
  TextBlock,
  ThinkingBlock,
  TranscriptModel
} from "./types";

export function applyAssistant(
  model: TranscriptModel,
  index: TranscriptIndex,
  line: AssistantLine,
  nowMs: number
): TranscriptModel {
  if (line.uuid) {
    if (index.seenUuids.has(line.uuid)) return model;
    index.seenUuids.add(line.uuid);
  }
  let next = model;
  if (line.supersedes && line.supersedes.length > 0) {
    next = evictUuids(next, new Set(line.supersedes));
  }
  const parent = line.parent_tool_use_id ?? null;
  // The record's own clock when it has one — replayed frames arrive long after
  // they were written, and turns stamped at wall-now report nonsense spans.
  const stamp = line.timestamp ? Date.parse(line.timestamp) : Number.NaN;
  const atMs = Number.isFinite(stamp) ? stamp : nowMs;
  // A MAIN-thread frame names the model that actually produced it. This is the
  // one model signal a replayed session has (history carries no init frame),
  // and on a live session it tracks /model switches the moment they take
  // effect. Subagent frames are excluded: an agent's model is not the session's.
  const wireModel = !parent ? asString(line.message.model) : undefined;
  if (wireModel && wireModel !== next.lastAssistantModel) {
    next = { ...next, lastAssistantModel: wireModel };
  }
  // The SAME frame builds two things: the inline block tree the transcript
  // nests under the launching Task card, and the agent's own thread, which is
  // what the agent view renders. One frame, two folds — never two sources.
  if (parent) next = applyAssistantToThread(next, line, parent, nowMs);
  else next = registerRootSpawns(next, line.message.content, nowMs);
  const ensured = ensureTurn(next, index, atMs, parent);
  next = ensured.model;
  let turnIndex = ensured.turnIndex;
  {
    const turn = next.turns[turnIndex];
    if (turn && turn.lastFrameAtMs !== atMs) {
      next = withTurn(next, turnIndex, { ...turn, lastFrameAtMs: atMs });
    }
  }
  const messageId = line.message.id ?? `msg:${line.uuid ?? next.revision}`;

  if (line.error) {
    const text =
      typeof line.error === "string"
        ? line.error
        : line.error.message ?? line.error.type ?? "Model error";
    const kind = errorKindOf(typeof line.error === "string" ? undefined : line.error.type);
    next = appendNotice(next, "error", text, `err:${line.uuid ?? next.revision}`, turnIndex, kind);
    const turn = next.turns[turnIndex];
    return withTurn(next, turnIndex, {
      ...settleTurn(turn, atMs),
      state: "error",
      errorText: text
    });
  }

  for (const content of line.message.content ?? []) {
    next = mergeAssistantBlock(next, index, turnIndex, content, messageId, line, atMs, parent);
    turnIndex = findTurnIndex(next, ensured.turnId);
    if (turnIndex < 0) return next;
  }
  if (line.aborted) {
    const marked = markTurnAborted(next.turns[turnIndex], atMs);
    next = withTurn(next, turnIndex, { ...marked, blocks: flagAborted(marked.blocks, line.uuid) });
  }
  return next;
}

/**
 * The CLI's `error.type` is a machine token; the transcript needs a heading a
 * reader can act on ("Usage limit reached" tells you to wait or switch model,
 * "rate_limit" does not).
 */
function errorKindOf(type: string | undefined): NoticeErrorKind {
  switch (type) {
    case "authentication_failed":
      return "auth";
    case "billing_error":
      return "billing";
    case "rate_limit":
      return "rateLimit";
    default:
      return "generic";
  }
}

function flagAborted(blocks: Block[], uuid: string | undefined): Block[] {
  if (!uuid) return blocks;
  return blocks.map((block) => {
    if (block.kind === "tool") return { ...block, children: flagAborted(block.children, uuid) };
    if ("uuid" in block && block.uuid === uuid) return { ...block, aborted: true } as Block;
    return block;
  });
}

function mergeAssistantBlock(
  model: TranscriptModel,
  index: TranscriptIndex,
  turnIndex: number,
  content: ContentBlock,
  messageId: string,
  line: AssistantLine,
  nowMs: number,
  parent: string | null
): TranscriptModel {
  const turn = model.turns[turnIndex];
  if (!turn) return model;
  if (content.type === "text") {
    const text = asString((content as { text?: string }).text) ?? "";
    const path = findOpenBlock(turn, messageId, "text", index);
    const existing = path ? (blockAtPath(turn, path) as TextBlock) : undefined;
    const block = mergeTextBlock(
      existing,
      existing?.key ?? nextBlockKey(index, messageId),
      messageId,
      text,
      line.uuid
    );
    index.finalizedBlocks.add(block.key);
    if (path) return writeBlock(model, { turnIndex, path }, block);
    return insertBlock(model, index, turnIndex, block, parent).model;
  }
  if (content.type === "thinking") {
    const text = asString((content as { thinking?: string }).thinking) ?? "";
    const signature = asString((content as { signature?: string }).signature);
    const path = findOpenBlock(turn, messageId, "thinking", index);
    const existing = path ? (blockAtPath(turn, path) as ThinkingBlock) : undefined;
    const block = mergeThinkingBlock(
      existing,
      existing?.key ?? nextBlockKey(index, messageId),
      messageId,
      text,
      signature,
      line.uuid,
      nowMs,
      model.activity.thinkingTokens
    );
    index.finalizedBlocks.add(block.key);
    if (path) return writeBlock(model, { turnIndex, path }, block);
    return insertBlock(model, index, turnIndex, block, parent).model;
  }
  if (content.type === "tool_use") {
    const tool = content as { id: string; name: string; input?: JsonObject };
    const existing = readTool(model, index, tool.id);
    const block = mergeToolUseBlock(
      existing?.block,
      existing?.block.key ?? nextBlockKey(index, messageId),
      messageId,
      tool,
      line.uuid,
      nowMs
    );
    index.finalizedBlocks.add(block.key);
    if (existing) return writeBlock(model, existing.location, block);
    return insertBlock(model, index, turnIndex, block, parent).model;
  }
  return model;
}


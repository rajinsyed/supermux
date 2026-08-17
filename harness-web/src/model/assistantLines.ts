import type { AssistantLine, ContentBlock, JsonObject } from "../protocol/types";
import {
  evictUuids,
  findOpenBlock,
  insertBlock,
  makeTextBlock,
  makeThinkingBlock,
  makeToolBlock,
  markTurnAborted,
  readTool,
  settleTurn,
  writeBlock
} from "./blocks";
import { asString, blockAtPath, findTurnIndex, isTaskTool, withTurn, type TranscriptIndex } from "./helpers";
import { appendNotice, ensureTurn, nextBlockKey } from "./turns";
import type {
  Block,
  NoticeErrorKind,
  TextBlock,
  ThinkingBlock,
  ToolBlock,
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
  const ensured = ensureTurn(next, index, nowMs, parent);
  next = ensured.model;
  let turnIndex = ensured.turnIndex;
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
      ...settleTurn(turn, nowMs),
      state: "error",
      errorText: text
    });
  }

  for (const content of line.message.content ?? []) {
    next = mergeAssistantBlock(next, index, turnIndex, content, messageId, line, nowMs, parent);
    turnIndex = findTurnIndex(next, ensured.turnId);
    if (turnIndex < 0) return next;
  }
  if (line.aborted) {
    const marked = markTurnAborted(next.turns[turnIndex], nowMs);
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
    if (path) {
      const existing = blockAtPath(turn, path) as TextBlock;
      index.finalizedBlocks.add(existing.key);
      return writeBlock(model, { turnIndex, path }, {
        ...existing,
        text,
        streaming: false,
        uuid: line.uuid
      });
    }
    const block = makeTextBlock(nextBlockKey(index, messageId), messageId, text, false);
    block.uuid = line.uuid;
    index.finalizedBlocks.add(block.key);
    return insertBlock(model, index, turnIndex, block, parent).model;
  }
  if (content.type === "thinking") {
    const text = asString((content as { thinking?: string }).thinking) ?? "";
    const signature = asString((content as { signature?: string }).signature);
    const path = findOpenBlock(turn, messageId, "thinking", index);
    if (path) {
      const existing = blockAtPath(turn, path) as ThinkingBlock;
      index.finalizedBlocks.add(existing.key);
      return writeBlock(model, { turnIndex, path }, {
        ...existing,
        text: text.length > 0 ? text : existing.text,
        signature,
        streaming: false,
        endedAtMs: existing.endedAtMs ?? nowMs,
        uuid: line.uuid
      });
    }
    const block = makeThinkingBlock(nextBlockKey(index, messageId), messageId, text, false, nowMs);
    block.uuid = line.uuid;
    block.signature = signature;
    block.endedAtMs = nowMs;
    block.tokens = model.activity.thinkingTokens;
    index.finalizedBlocks.add(block.key);
    return insertBlock(model, index, turnIndex, block, parent).model;
  }
  if (content.type === "tool_use") {
    const tool = content as { id: string; name: string; input?: JsonObject };
    const existing = readTool(model, index, tool.id);
    if (existing) {
      index.finalizedBlocks.add(existing.block.key);
      return writeBlock(model, existing.location, {
        ...existing.block,
        input: tool.input ?? existing.block.input,
        inputComplete: true,
        streaming: false,
        status: existing.block.status === "pending" ? "running" : existing.block.status,
        uuid: line.uuid,
        subagent: isTaskTool(tool.name)
          ? {
              ...existing.block.subagent,
              subagentType: asString(tool.input?.subagent_type) ?? existing.block.subagent?.subagentType,
              description: asString(tool.input?.description) ?? existing.block.subagent?.description,
              status: existing.block.subagent?.status ?? "running"
            }
          : existing.block.subagent
      });
    }
    const block = makeToolBlock(
      nextBlockKey(index, messageId),
      messageId,
      tool.id,
      tool.name,
      tool.input ?? {},
      false,
      nowMs
    );
    block.uuid = line.uuid;
    if (isTaskTool(tool.name)) {
      block.subagent = {
        subagentType: asString(tool.input?.subagent_type),
        description: asString(tool.input?.description),
        status: "running"
      };
    }
    index.finalizedBlocks.add(block.key);
    return insertBlock(model, index, turnIndex, block, parent).model;
  }
  return model;
}


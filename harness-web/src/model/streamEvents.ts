import type { JsonObject, StreamEventLine } from "../protocol/types";
import {
  insertBlock,
  locateByKey,
  makeTextBlock,
  makeThinkingBlock,
  makeToolBlock,
  writeBlock
} from "./blocks";
import {
  adoptSessionModel,
  asString,
  blockAtPath,
  isTaskTool,
  parsePartialJson,
  streamScope,
  withTurn,
  type TranscriptIndex
} from "./helpers";
import { ensureTurn } from "./turns";
import type { Block, TextBlock, ThinkingBlock, ToolBlock, TranscriptModel } from "./types";

export function applyStreamEvent(
  model: TranscriptModel,
  index: TranscriptIndex,
  line: StreamEventLine,
  nowMs: number
): TranscriptModel {
  if (line.uuid) {
    if (index.seenUuids.has(line.uuid)) return model;
    index.seenUuids.add(line.uuid);
  }
  const event = line.event;
  const parent = line.parent_tool_use_id ?? null;
  const scope = streamScope(parent);
  switch (event.type) {
    case "message_start": {
      const messageId = event.message?.id;
      if (!messageId) return model;
      index.streamMessageIds.set(scope, messageId);
      const ensured = ensureTurn(model, index, nowMs, parent);
      const turn = ensured.model.turns[ensured.turnIndex];
      const model2 =
        event.message?.model && event.message.model !== model.session.model && !parent
          ? {
              ...ensured.model,
              session: adoptSessionModel(
                ensured.model.session,
                ensured.model.cachedModels,
                event.message.model
              )
            }
          : ensured.model;
      return withTurn(model2, ensured.turnIndex, { ...turn, state: "streaming" });
    }
    case "content_block_start":
      return startStreamBlock(model, index, line, nowMs, scope, parent);
    case "content_block_delta":
      return deltaStreamBlock(model, index, line, scope);
    case "content_block_stop": {
      if (typeof event.index !== "number") return model;
      const messageId = index.streamMessageIds.get(scope);
      if (!messageId) return model;
      const location = locateByKey(model, index, `${messageId}#${event.index}`);
      if (!location) return model;
      const target = blockAtPath(model.turns[location.turnIndex], location.path);
      if (!target) return model;
      index.finalizedBlocks.add(target.key);
      if (target.kind === "text") {
        return writeBlock(model, location, { ...target, streaming: false });
      }
      if (target.kind === "thinking") {
        return writeBlock(model, location, {
          ...target,
          streaming: false,
          endedAtMs: nowMs
        });
      }
      if (target.kind === "tool") {
        return writeBlock(model, location, {
          ...target,
          partialInput: undefined,
          streaming: false,
          inputComplete: true,
          status: target.status === "pending" ? "running" : target.status
        });
      }
      return model;
    }
    case "message_stop": {
      const messageId = index.streamMessageIds.get(scope);
      index.streamMessageIds.delete(scope);
      return messageId ? clearMessagePartials(model, index, messageId) : model;
    }
    default:
      return model;
  }
}

function startStreamBlock(
  model: TranscriptModel,
  index: TranscriptIndex,
  line: StreamEventLine,
  nowMs: number,
  scope: string,
  parent: string | null
): TranscriptModel {
  const block = line.event.content_block;
  if (!block || typeof line.event.index !== "number") return model;
  const blockIndex = line.event.index;
  const ensured = ensureTurn(model, index, nowMs, parent);
  const messageId = index.streamMessageIds.get(scope) ?? `stream:${scope}`;
  const key = `${messageId}#${blockIndex}`;
  if (locateByKey(ensured.model, index, key)) return ensured.model;
  let created: Block | undefined;
  if (block.type === "text") {
    created = makeTextBlock(key, messageId, asString((block as { text?: string }).text) ?? "", true);
  } else if (block.type === "thinking") {
    created = makeThinkingBlock(
      key,
      messageId,
      asString((block as { thinking?: string }).thinking) ?? "",
      true,
      nowMs
    );
  } else if (block.type === "tool_use") {
    const tool = block as { id: string; name: string; input?: JsonObject };
    if (index.toolLocations.has(tool.id)) return ensured.model;
    const toolBlock = makeToolBlock(key, messageId, tool.id, tool.name, tool.input ?? {}, true, nowMs);
    if (isTaskTool(tool.name)) toolBlock.subagent = { status: "running" };
    created = toolBlock;
  }
  if (!created) return ensured.model;
  return insertBlock(ensured.model, index, ensured.turnIndex, created, parent).model;
}

function deltaStreamBlock(
  model: TranscriptModel,
  index: TranscriptIndex,
  line: StreamEventLine,
  scope: string
): TranscriptModel {
  if (typeof line.event.index !== "number") return model;
  const messageId = index.streamMessageIds.get(scope);
  if (!messageId) return model;
  const location = locateByKey(model, index, `${messageId}#${line.event.index}`);
  if (!location) return model;
  const target = blockAtPath(model.turns[location.turnIndex], location.path);
  if (!target) return model;
  const delta = line.event.delta ?? {};
  if (target.kind === "text" && typeof delta.text === "string") {
    return writeBlock(model, location, { ...target, text: target.text + delta.text } as TextBlock);
  }
  if (target.kind === "thinking") {
    if (typeof delta.thinking === "string" && delta.thinking.length > 0) {
      return writeBlock(model, location, {
        ...target,
        text: target.text + delta.thinking
      } as ThinkingBlock);
    }
    if (typeof delta.estimated_tokens === "number") {
      return writeBlock(model, location, {
        ...target,
        tokens: delta.estimated_tokens
      } as ThinkingBlock);
    }
    return model;
  }
  if (
    target.kind === "tool" &&
    target.streaming &&
    !target.inputComplete &&
    typeof delta.partial_json === "string"
  ) {
    const partial = (target.partialInput ?? "") + delta.partial_json;
    const parsed = parsePartialJson(partial);
    return writeBlock(model, location, {
      ...target,
      partialInput: partial,
      input: parsed ?? target.input
    } as ToolBlock);
  }
  return model;
}

function clearMessagePartials(
  model: TranscriptModel,
  index: TranscriptIndex,
  messageId: string
): TranscriptModel {
  let next = model;
  const prefix = `${messageId}#`;
  for (const key of index.streamBlockKeys.keys()) {
    if (!key.startsWith(prefix)) continue;
    const location = locateByKey(next, index, key);
    if (!location) continue;
    const target = blockAtPath(next.turns[location.turnIndex], location.path);
    if (!target || target.kind !== "tool" || target.partialInput === undefined) continue;
    next = writeBlock(next, location, { ...target, partialInput: undefined, inputComplete: true });
  }
  return next;
}

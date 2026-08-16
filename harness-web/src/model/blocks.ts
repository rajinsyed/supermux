import type { JsonObject } from "../protocol/types";
import type { Block, TextBlock, ThinkingBlock, ToolBlock, TranscriptModel, Turn } from "./types";
import {
  appendBlock,
  blockAtPath,
  findTurnIndex,
  replaceBlockAtPath,
  withTurn,
  type ToolLocation,
  type TranscriptIndex
} from "./helpers";

export interface BlockLocation {
  turnIndex: number;
  path: number[];
}

export function locateTool(
  model: TranscriptModel,
  index: TranscriptIndex,
  toolUseId: string
): BlockLocation | undefined {
  const loc = index.toolLocations.get(toolUseId);
  if (!loc) return undefined;
  const turnIndex = findTurnIndex(model, loc.turnId);
  if (turnIndex < 0) return undefined;
  return { turnIndex, path: loc.path };
}

export function readTool(
  model: TranscriptModel,
  index: TranscriptIndex,
  toolUseId: string
): { location: BlockLocation; block: ToolBlock } | undefined {
  const location = locateTool(model, index, toolUseId);
  if (!location) return undefined;
  const block = blockAtPath(model.turns[location.turnIndex], location.path);
  if (!block || block.kind !== "tool") return undefined;
  return { location, block };
}

export function writeBlock(
  model: TranscriptModel,
  location: BlockLocation,
  block: Block
): TranscriptModel {
  const turn = model.turns[location.turnIndex];
  if (!turn) return model;
  return withTurn(model, location.turnIndex, replaceBlockAtPath(turn, location.path, block));
}

export function insertBlock(
  model: TranscriptModel,
  index: TranscriptIndex,
  turnIndex: number,
  block: Block,
  parentToolUseId?: string | null
): { model: TranscriptModel; location: BlockLocation } {
  const turn = model.turns[turnIndex];
  let parentPath: number[] | undefined;
  if (parentToolUseId) {
    const parent = index.toolLocations.get(parentToolUseId);
    if (parent && parent.turnId === turn.id) parentPath = parent.path;
  }
  const appended = appendBlock(turn, block, parentPath);
  const nextModel = withTurn(model, turnIndex, appended.turn);
  const location = { turnIndex, path: appended.path };
  if (block.kind === "tool") {
    const record: ToolLocation = { turnId: turn.id, path: appended.path };
    index.toolLocations.set(block.toolUseId, record);
  }
  index.streamBlockKeys.set(block.key, `${turn.id}|${appended.path.join(".")}`);
  return { model: nextModel, location };
}

export function locateByKey(
  model: TranscriptModel,
  index: TranscriptIndex,
  key: string
): BlockLocation | undefined {
  const raw = index.streamBlockKeys.get(key);
  if (!raw) return undefined;
  const [turnId, pathText] = raw.split("|");
  const turnIndex = findTurnIndex(model, turnId);
  if (turnIndex < 0) return undefined;
  const path = pathText.length ? pathText.split(".").map(Number) : [];
  return { turnIndex, path };
}

export function findOpenBlock(
  turn: Turn,
  messageId: string,
  kind: Block["kind"],
  index: TranscriptIndex,
  predicate?: (block: Block) => boolean
): number[] | undefined {
  const walk = (blocks: Block[], prefix: number[]): number[] | undefined => {
    for (let i = blocks.length - 1; i >= 0; i -= 1) {
      const block = blocks[i];
      const path = prefix.concat(i);
      if (block.kind === "tool") {
        const nested = walk(block.children, path);
        if (nested) return nested;
      }
      if (block.kind !== kind) continue;
      if (index.finalizedBlocks.has(block.key)) continue;
      if ("messageId" in block && block.messageId !== messageId) continue;
      if (predicate && !predicate(block)) continue;
      return path;
    }
    return undefined;
  };
  return walk(turn.blocks, []);
}

export function makeTextBlock(key: string, messageId: string, text: string, streaming: boolean): TextBlock {
  return { kind: "text", key, messageId, text, streaming };
}

export function makeThinkingBlock(
  key: string,
  messageId: string,
  text: string,
  streaming: boolean,
  atMs: number
): ThinkingBlock {
  return { kind: "thinking", key, messageId, text, tokens: 0, streaming, startedAtMs: atMs };
}

export function makeToolBlock(
  key: string,
  messageId: string,
  toolUseId: string,
  name: string,
  input: JsonObject,
  streaming: boolean,
  atMs: number
): ToolBlock {
  return {
    kind: "tool",
    key,
    messageId,
    toolUseId,
    name,
    input,
    inputComplete: !streaming,
    status: streaming ? "pending" : "running",
    streaming,
    startedAtMs: atMs,
    children: []
  };
}

export function evictUuids(model: TranscriptModel, uuids: Set<string>): TranscriptModel {
  if (uuids.size === 0) return model;
  let changed = false;
  const filter = (blocks: Block[]): Block[] => {
    const next: Block[] = [];
    for (const block of blocks) {
      if ("uuid" in block && block.uuid && uuids.has(block.uuid)) {
        changed = true;
        continue;
      }
      if (block.kind === "tool" && block.children.length > 0) {
        next.push({ ...block, children: filter(block.children) });
      } else {
        next.push(block);
      }
    }
    return next;
  };
  const turns = model.turns.map((turn) => {
    const blocks = filter(turn.blocks);
    return blocks === turn.blocks ? turn : { ...turn, blocks, revision: turn.revision + 1 };
  });
  return changed ? { ...model, turns, revision: model.revision + 1 } : model;
}

export function markTurnAborted(turn: Turn, atMs: number): Turn {
  const abort = (blocks: Block[]): Block[] =>
    blocks.map((block) => {
      if (block.kind === "tool") {
        const children = abort(block.children);
        if (block.status === "running" || block.status === "pending") {
          return { ...block, children, status: "aborted", streaming: false, aborted: true, endedAtMs: atMs };
        }
        return children === block.children ? block : { ...block, children };
      }
      if ((block.kind === "text" || block.kind === "thinking") && block.streaming) {
        return { ...block, streaming: false, aborted: true };
      }
      return block;
    });
  return { ...turn, blocks: abort(turn.blocks), state: "aborted", endedAtMs: atMs, revision: turn.revision + 1 };
}

export function settleTurn(turn: Turn, atMs: number): Turn {
  const settle = (blocks: Block[]): Block[] =>
    blocks.map((block) => {
      if (block.kind === "tool") {
        const children = settle(block.children);
        if (block.status === "running" || block.status === "pending") {
          return { ...block, children, status: "success", streaming: false, endedAtMs: atMs };
        }
        return children === block.children ? block : { ...block, children };
      }
      if ((block.kind === "text" || block.kind === "thinking") && block.streaming) {
        return { ...block, streaming: false };
      }
      return block;
    });
  return { ...turn, blocks: settle(turn.blocks), endedAtMs: atMs, revision: turn.revision + 1 };
}

import type { JsonObject, PermissionMode } from "../protocol/types";
import type {
  Block,
  PendingKind,
  SessionMeta,
  ToolBlock,
  TranscriptModel,
  Turn,
  UsageTotals
} from "./types";

export interface ToolLocation {
  turnId: string;
  path: number[];
}

export interface TranscriptIndex {
  seenUuids: Set<string>;
  toolLocations: Map<string, ToolLocation>;
  taskToTool: Map<string, string>;
  finalizedBlocks: Set<string>;
  streamBlockKeys: Map<string, string>;
  streamMessageIds: Map<string, string>;
  nextSeq: number;
  blockCounter: number;
}

export function createIndex(): TranscriptIndex {
  return {
    seenUuids: new Set(),
    toolLocations: new Map(),
    taskToTool: new Map(),
    finalizedBlocks: new Set(),
    streamBlockKeys: new Map(),
    streamMessageIds: new Map(),
    nextSeq: 1,
    blockCounter: 0
  };
}

export function streamScope(parent: string | null | undefined): string {
  return parent ?? "@root";
}

export function emptySession(): SessionMeta {
  return {
    permissionMode: "default",
    tools: [],
    slashCommands: [],
    commands: [],
    models: [],
    agents: [],
    skills: [],
    mcpServers: [],
    capabilities: []
  };
}

export function emptyUsage(): UsageTotals {
  return {
    costUsd: 0,
    inputTokens: 0,
    outputTokens: 0,
    thinkingTokens: 0,
    cacheReadTokens: 0,
    cacheCreationTokens: 0,
    turns: 0
  };
}

export function isPlainObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

export function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

export function permissionModeOf(value: unknown): PermissionMode | undefined {
  if (
    value === "default" ||
    value === "acceptEdits" ||
    value === "plan" ||
    value === "bypassPermissions"
  ) {
    return value;
  }
  return undefined;
}

export function permissionKindFor(toolName: string): PendingKind {
  if (toolName === "AskUserQuestion") return "question";
  if (toolName === "ExitPlanMode") return "plan";
  if (toolName === "EnterPlanMode") return "enterPlan";
  return "permission";
}

export function isTaskTool(name: string): boolean {
  return name === "Task" || name === "Agent";
}

export function blockAtPath(turn: Turn, path: number[]): Block | undefined {
  let list: Block[] = turn.blocks;
  let block: Block | undefined;
  for (const step of path) {
    block = list[step];
    if (!block) return undefined;
    list = block.kind === "tool" ? block.children : [];
  }
  return block;
}

export function replaceBlockAtPath(turn: Turn, path: number[], next: Block): Turn {
  const [head, ...rest] = path;
  const blocks = turn.blocks.slice();
  if (rest.length === 0) {
    blocks[head] = next;
  } else {
    const parent = blocks[head];
    if (!parent || parent.kind !== "tool") return turn;
    blocks[head] = replaceChild(parent, rest, next);
  }
  return { ...turn, blocks, revision: turn.revision + 1 };
}

function replaceChild(parent: ToolBlock, path: number[], next: Block): ToolBlock {
  const [head, ...rest] = path;
  const children = parent.children.slice();
  if (rest.length === 0) {
    children[head] = next;
  } else {
    const child = children[head];
    if (!child || child.kind !== "tool") return parent;
    children[head] = replaceChild(child, rest, next);
  }
  return { ...parent, children };
}

export function appendBlock(turn: Turn, block: Block, parentPath?: number[]): { turn: Turn; path: number[] } {
  if (!parentPath || parentPath.length === 0) {
    const blocks = turn.blocks.concat(block);
    return {
      turn: { ...turn, blocks, revision: turn.revision + 1 },
      path: [blocks.length - 1]
    };
  }
  const parent = blockAtPath(turn, parentPath);
  if (!parent || parent.kind !== "tool") {
    const blocks = turn.blocks.concat(block);
    return {
      turn: { ...turn, blocks, revision: turn.revision + 1 },
      path: [blocks.length - 1]
    };
  }
  const nextParent: ToolBlock = { ...parent, children: parent.children.concat(block) };
  const childPath = parentPath.concat(nextParent.children.length - 1);
  return { turn: replaceBlockAtPath(turn, parentPath, nextParent), path: childPath };
}

export function findTurnIndex(model: TranscriptModel, turnId: string): number {
  for (let i = model.turns.length - 1; i >= 0; i -= 1) {
    if (model.turns[i].id === turnId) return i;
  }
  return -1;
}

export function withTurn(model: TranscriptModel, index: number, turn: Turn): TranscriptModel {
  if (index < 0) return model;
  const turns = model.turns.slice();
  turns[index] = turn;
  return { ...model, turns, revision: model.revision + 1 };
}

export function activeTurnIndex(model: TranscriptModel): number {
  for (let i = model.turns.length - 1; i >= 0; i -= 1) {
    if (model.turns[i].state === "streaming") return i;
  }
  return -1;
}

export function unresolvedTurnIndex(model: TranscriptModel): number {
  for (let i = model.turns.length - 1; i >= 0; i -= 1) {
    const turn = model.turns[i];
    if (turn.result) return -1;
    if (turn.state === "streaming" || turn.state === "aborted" || turn.state === "error") return i;
  }
  return -1;
}

export function firstNonEmptyLine(text: string): string {
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.length > 0) return trimmed;
  }
  return text.trim();
}

export function deriveTitle(text: string): string {
  const line = firstNonEmptyLine(text).replace(/^[#>\-*\s]+/, "");
  return line.length > 64 ? `${line.slice(0, 61)}…` : line;
}

export function tryParseJson(text: string): JsonObject | undefined {
  if (!text.trim()) return undefined;
  try {
    const parsed = JSON.parse(text);
    return isPlainObject(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

const CLOSERS: Record<string, string> = { "{": "}", "[": "]" };

export function parsePartialJson(text: string): JsonObject | undefined {
  const direct = tryParseJson(text);
  if (direct) return direct;
  const stack: string[] = [];
  let inString = false;
  let escaped = false;
  for (const char of text) {
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\" && inString) {
      escaped = true;
      continue;
    }
    if (char === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (char === "{" || char === "[") stack.push(CLOSERS[char]);
    else if (char === "}" || char === "]") stack.pop();
  }
  let candidate = text;
  if (inString) candidate += '"';
  candidate = candidate.replace(/,\s*$/, "").replace(/:\s*$/, ": null");
  for (let i = stack.length - 1; i >= 0; i -= 1) candidate += stack[i];
  return tryParseJson(candidate);
}

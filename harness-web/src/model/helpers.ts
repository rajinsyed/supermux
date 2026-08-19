import type { EffortLevel, JsonObject, ModelDescriptor, PermissionMode } from "../protocol/types";
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
    permissionMode: "bypassPermissions",
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

/**
 * A model id with its bracketed variant suffix removed ("claude-opus-5[1m]" →
 * "claude-opus-5").
 *
 * The catalog and the wire spell the SAME model three ways: the selector can
 * carry the suffix ("opus[1m]"), the catalog's resolved id can carry it
 * ("claude-opus-5[1m]"), and the assistant frames' `message.model` stamps the
 * bare API id ("claude-opus-5") — the live probe against the user's binary
 * shows all three at once (`--model 'opus[1m]'` → init "claude-opus-5[1m]" →
 * assistant "claude-opus-5"). Any comparison that decides "same model or not"
 * has to strip the suffix from BOTH sides or a send renames the picker to a
 * raw slug.
 */
export function baseModelId(id: string): string {
  return id.replace(/\[[^\]]*\]$/, "");
}

/** Whether two wire/catalog model ids denote the same model. */
export function sameModelId(a: string, b: string): boolean {
  return a === b || baseModelId(a) === baseModelId(b);
}

/**
 * `system/init` reports the RESOLVED model id ("claude-sonnet-5"), while the
 * catalog from `initialize` is keyed by short selector ("sonnet"). The two
 * namespaces never overlap on a real session, so matching only on `value` leaves
 * the pill printing a raw id, no menu row checked, and the effort submenu — which
 * is gated on the active model — unreachable. Both identifiers resolve here so
 * the header and the empty state cannot drift apart.
 *
 * Matching runs in falling strictness: exact value, exact resolved id, then the
 * same two with the `[1m]`-style suffix stripped from both sides — the wire
 * stamps "claude-opus-5" for a session the catalog only knows as
 * "opus[1m]" / "claude-opus-5[1m]", and strict equality left that session
 * displaying the raw id. Within the resolved-id passes a CONCRETE row outranks
 * the "default" alias row: both resolve to the same model, but "Opus (1M
 * context)" names it and "Default (recommended)" does not — the alias row
 * listing first must not rename a resolvable model.
 */
export function activeModelFor(
  session: Pick<SessionMeta, "models" | "model">
): ModelDescriptor | undefined {
  const id = session.model;
  if (!id) return undefined;
  const models = session.models;
  const preferConcrete = (
    pred: (m: ModelDescriptor) => boolean
  ): ModelDescriptor | undefined =>
    models.find((m) => m.value !== "default" && pred(m)) ?? models.find(pred);
  const bare = baseModelId(id);
  return (
    models.find((m) => m.value === id) ??
    preferConcrete((m) => m.resolvedModel === id) ??
    preferConcrete((m) => baseModelId(m.value) === bare) ??
    preferConcrete((m) => m.resolvedModel !== undefined && baseModelId(m.resolvedModel) === bare)
  );
}

/**
 * The active model resolved against BOTH catalogs the pane can have.
 *
 * `session.models` only exists once a process has run its `initialize`
 * handshake, so on a pane that has never started it is empty — and a model the
 * user picks before the first send has nothing to resolve against. It rendered
 * as the bare selector the menu sends on the wire ("opus"), sitting next to a
 * menu whose "Opus 5" row was correctly checked from the cached catalog. The
 * cache is that same catalog from that same binary, so it answers just as well.
 */
export function resolveModel(
  session: Pick<SessionMeta, "models" | "model"> & { defaultModel?: string },
  cachedModels: ModelDescriptor[] | undefined
): ModelDescriptor | undefined {
  const resolveAgainstBoth = (id: string | undefined): ModelDescriptor | undefined =>
    activeModelFor({ models: session.models, model: id }) ??
    (cachedModels && cachedModels.length > 0
      ? activeModelFor({ models: cachedModels, model: id })
      : undefined);
  const active = resolveAgainstBoth(session.model);
  if (active) return active;
  // NO selection at all — a pane that has never started a process and carries
  // no restore. Item 12: what that pane will ACTUALLY run is the CLI's own
  // settings default (`~/.claude/settings.json` "model", surfaced as
  // `session.defaultModel`), so that row is named first. The catalog's generic
  // "default" row is the fallback when the settings name nothing resolvable —
  // still more honest than the bare "Model" placeholder.
  if (!session.model) {
    return (
      resolveAgainstBoth(session.defaultModel) ??
      session.models.find((m) => m.value === "default") ??
      cachedModels?.find((m) => m.value === "default")
    );
  }
  return undefined;
}

/**
 * The session, having adopted a model the WIRE reported — `system/init`'s
 * `model`, or a main-thread assistant frame's `message.model`. A carried effort
 * belongs to the model it was selected for: the picker uses a selector
 * ("sonnet") while the wire reports the resolved id ("claude-sonnet-5"), so the
 * two are compared through the catalog before deciding the session actually
 * changed models and the effort must be dropped.
 */
export function adoptSessionModel(
  session: SessionMeta,
  cachedModels: ModelDescriptor[] | undefined,
  wireModel: string
): SessionMeta {
  const confirmsSelection = wireMatchesSelection(session, cachedModels, wireModel);
  // A pick the wire has not yet honored outranks a wire frame naming a
  // DIFFERENT model: that frame describes the state the pick is about to
  // change — the in-flight turn's message_start, or the init of a restart
  // whose start params were built before the pick landed — and adopting it
  // snapped the picker back to the model the process launched with the moment
  // the user chose something else. The pick is not merely display: it rides
  // `set_model` on a live process and `startOptions` onto the next start, so
  // the wire converges on it and the next confirming frame clears the latch.
  // Every deliberate move onto ANOTHER session's model (resume, New Session)
  // resets the conversation first, which clears the latch, so a resumed
  // session's own recorded model still wins.
  if (session.modelPickPending && !confirmsSelection) return session;
  if (confirmsSelection) {
    return { ...session, model: wireModel, modelPickPending: undefined };
  }
  return { ...session, model: wireModel, effort: undefined, modelPickPending: undefined };
}

/**
 * Whether a model id the WIRE reported denotes the same model the session has
 * selected. The wire may spell it without the catalog's variant suffix
 * ("claude-opus-5" for a session running "opus[1m]" / "claude-opus-5[1m]"), so
 * the pick's catalog row is compared against the wire id with the suffix
 * stripped from both sides. Also the guard `applyInit` uses to decide whether
 * an init frame CONFIRMS a pending pick or describes the launch state a
 * mid-restart pick is about to override.
 */
export function wireMatchesSelection(
  session: Pick<SessionMeta, "models" | "model"> & { defaultModel?: string },
  cachedModels: ModelDescriptor[] | undefined,
  wireModel: string
): boolean {
  if (session.model !== undefined && sameModelId(session.model, wireModel)) return true;
  if (!session.model) return false;
  const selected = resolveModel(session, cachedModels);
  if (!selected) return false;
  return (
    sameModelId(selected.value, wireModel) ||
    (selected.resolvedModel !== undefined && sameModelId(selected.resolvedModel, wireModel))
  );
}

/**
 * The effort that is ACTUALLY in force, which is never "none" on a model that
 * supports effort: when the session carries no explicit level (a fresh pane, a
 * resume, a model switch that dropped the carried level), the CLI runs at a
 * default anyway — the catalog's per-model `defaultEffortLevel` when it ships
 * one, or the CLI's own settings default (`~/.claude/settings.json
 * effortLevel`, delivered as `session.defaultEffort`). Every surface that
 * shows effort reads this; showing nothing while the CLI runs at `xhigh` told
 * the user reasoning was somehow off. `session.effort` stays the record of an
 * EXPLICIT pick — the "Restore defaults" affordance keys off that difference —
 * and this is the display answer layered over it.
 */
export function effectiveEffort(
  model: ModelDescriptor | undefined,
  explicit: EffortLevel | undefined,
  inherited?: EffortLevel
): EffortLevel | undefined {
  if (!model?.supportsEffort) return undefined;
  const levels = model.supportedEffortLevels;
  if (!levels || levels.length === 0) return undefined;
  if (explicit && levels.includes(explicit)) return explicit;
  if (inherited && levels.includes(inherited)) return inherited;
  return model.defaultEffortLevel;
}

/** The wire's effort strings, validated into the enum the session stores. */
export function effortLevelOf(value: unknown): EffortLevel | undefined {
  if (
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh" ||
    value === "max"
  ) {
    return value;
  }
  return undefined;
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

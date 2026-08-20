import type { AssistantLine, ContentBlock, JsonObject, UserLine } from "../protocol/types";
import { mergeTextBlock, mergeThinkingBlock, mergeToolUseBlock } from "./blocks";
import { asNumber, asString, isPlainObject, isTaskTool } from "./helpers";
import { classifyToolStatus } from "./toolStatus";
import { normalizeToolResultPayload } from "./toolResultPayload";
import type {
  AgentThread,
  Block,
  TaskRecord,
  TextBlock,
  ThinkingBlock,
  ToolBlock,
  ToolStatus,
  TranscriptModel,
  UserTextBlock
} from "./types";

/**
 * Agent threads, built live off the forwarded frames.
 *
 * ROUND4 wire fact, probed in fwd2.jsonl: with `forwardSubagentText` set, every
 * subagent frame carries `parent_tool_use_id` = its IMMEDIATE parent Agent
 * tool_use id. Outer agent toolu_A's frames say parent=toolu_A; the inner Agent
 * tool_use block ARRIVES on a frame with parent=toolu_A (so the spawn is
 * attributed to the outer thread), and the inner agent's own frames then say
 * parent=toolu_B. One rule builds the whole tree:
 *
 *   thread(X) = frames with parent_tool_use_id === X
 *   an Agent/Task tool_use with id Y inside thread X opens child thread Y
 *   main = parent null
 *
 * Threads live BESIDE the turns rather than replacing the inline nesting: the
 * transcript still shows a compact agent row where the work happened, and the
 * full conversation is read in the agent view. Both are the same frames, folded
 * twice, which is why this module reuses `blocks.ts`'s merge helpers rather than
 * inventing a second set of block semantics.
 */

const MAIN = "@main";

export function createThread(toolUseId: string, atMs: number, parentToolUseId?: string): AgentThread {
  return {
    toolUseId,
    parentToolUseId,
    childIds: [],
    blocks: [],
    startedAtMs: atMs,
    status: "running",
    revision: 0
  };
}

function writeThread(model: TranscriptModel, thread: AgentThread): TranscriptModel {
  return {
    ...model,
    agentThreads: {
      ...model.agentThreads,
      [thread.toolUseId]: { ...thread, revision: thread.revision + 1 }
    },
    revision: model.revision + 1
  };
}

/**
 * Ensure a thread exists for `toolUseId`, registering it with its parent.
 *
 * The parent link is set once, on creation. A frame is not allowed to re-parent
 * a thread later: the CLI can forward a nested agent's frames both under its own
 * id and, briefly, under the spawn's, and a thread that changed parents would
 * make the dock's tree jump under the reader mid-run.
 */
export function ensureThread(
  model: TranscriptModel,
  toolUseId: string,
  atMs: number,
  parentToolUseId?: string
): { model: TranscriptModel; thread: AgentThread } {
  const existing = model.agentThreads[toolUseId];
  if (existing) {
    if (parentToolUseId === undefined || existing.parentToolUseId !== undefined) {
      return { model, thread: existing };
    }
    // The thread was created by a frame before its spawning tool_use arrived, so
    // it has no parent yet. Adopting it now moves it off the dock's root list
    // and under the agent that actually started it.
    const adopted: AgentThread = { ...existing, parentToolUseId };
    let next = writeThread(model, adopted);
    next = {
      ...next,
      agentRootIds: next.agentRootIds.filter((id) => id !== toolUseId)
    };
    next = linkChild(next, parentToolUseId, toolUseId);
    return { model: next, thread: next.agentThreads[toolUseId] };
  }
  const thread = createThread(toolUseId, atMs, parentToolUseId);
  let next = writeThread(model, thread);
  if (parentToolUseId) {
    next = linkChild(next, parentToolUseId, toolUseId);
  } else {
    next = { ...next, agentRootIds: next.agentRootIds.concat(toolUseId) };
  }
  return { model: next, thread: next.agentThreads[toolUseId] };
}

function linkChild(model: TranscriptModel, parentId: string, childId: string): TranscriptModel {
  const parent = model.agentThreads[parentId];
  if (!parent || parent.childIds.includes(childId)) return model;
  return writeThread(model, { ...parent, childIds: parent.childIds.concat(childId) });
}

/**
 * The first live frame for a thread that was filled from disk.
 *
 * Both sources describe the SAME conversation, so keeping both draws it twice —
 * and the disk copy is the stale half: it is a snapshot of a file that was
 * still being written, while the live frames are the agent talking now. So the
 * first live frame clears the replay and the thread rebuilds from the wire.
 *
 * This is the other half of the reducer's existing "live frames always win"
 * rule. That rule only refused a hydration ONTO live blocks; a hydration that
 * got there FIRST — which is the normal race for an agent view opened the
 * instant its dock row appears — was never undone, and the thread then grew a
 * duplicate copy of everything the file already had.
 */
function takeLiveOver(thread: AgentThread): AgentThread {
  if (!thread.hydratedFromDisk) {
    return thread.hasLiveFrames ? thread : { ...thread, hasLiveFrames: true };
  }
  return { ...thread, blocks: [], hydratedFromDisk: undefined, hasLiveFrames: true };
}

/**
 * Find a block in a thread by key. Threads are FLAT — the tree lives in
 * `childIds`, not in nested `children` — so one linear scan is the whole lookup,
 * and a repeat frame for a block already present updates in place.
 */
function indexOfKey(blocks: Block[], key: string): number {
  for (let i = blocks.length - 1; i >= 0; i -= 1) {
    if (blocks[i].key === key) return i;
  }
  return -1;
}

function indexOfTool(blocks: Block[], toolUseId: string): number {
  for (let i = blocks.length - 1; i >= 0; i -= 1) {
    const block = blocks[i];
    if (block.kind === "tool" && block.toolUseId === toolUseId) return i;
  }
  return -1;
}

function putBlock(thread: AgentThread, at: number, block: Block): AgentThread {
  const blocks = thread.blocks.slice();
  if (at >= 0) blocks[at] = block;
  else blocks.push(block);
  return { ...thread, blocks };
}

/**
 * A forwarded assistant frame, folded into its agent's thread.
 *
 * Only ever called with a non-null parent: a null-parent frame is the MAIN
 * conversation, which the turns already own.
 */
export function applyAssistantToThread(
  model: TranscriptModel,
  line: AssistantLine,
  parentToolUseId: string,
  nowMs: number
): TranscriptModel {
  const ensured = ensureThread(model, parentToolUseId, nowMs);
  let next = ensured.model;
  let thread = ensured.thread;
  const messageId = line.message.id ?? `msg:${line.uuid ?? thread.blocks.length}`;
  const subagentType = asString((line as unknown as JsonObject).subagent_type);
  const description = asString((line as unknown as JsonObject).task_description);
  if (subagentType || description) {
    thread = {
      ...thread,
      subagentType: thread.subagentType ?? subagentType,
      description: thread.description ?? description
    };
  }
  thread = takeLiveOver(thread);

  for (const content of line.message.content ?? []) {
    thread = mergeContentIntoThread(thread, content, messageId, line.uuid, nowMs);
    // An Agent tool_use INSIDE this thread opens a child thread. The spawn is
    // attributed here (parent = this thread) and the child's own frames arrive
    // under its own id, which is exactly the round-4 nesting rule.
    if (content.type === "tool_use") {
      const tool = content as { id: string; name: string; input?: JsonObject };
      if (isTaskTool(tool.name)) {
        next = writeThread(next, thread);
        const child = ensureThread(next, tool.id, nowMs, parentToolUseId);
        next = child.model;
        next = writeThread(next, {
          ...next.agentThreads[tool.id],
          description: asString(tool.input?.description) ?? next.agentThreads[tool.id].description,
          subagentType:
            asString(tool.input?.subagent_type) ?? next.agentThreads[tool.id].subagentType
        });
        thread = next.agentThreads[parentToolUseId];
      }
    }
  }
  return writeThread(next, thread);
}

function mergeContentIntoThread(
  thread: AgentThread,
  content: ContentBlock,
  messageId: string,
  uuid: string | undefined,
  nowMs: number
): AgentThread {
  if (content.type === "text") {
    const key = `${thread.toolUseId}|${messageId}|text|${uuid ?? thread.blocks.length}`;
    const at = indexOfKey(thread.blocks, key);
    const existing = at >= 0 ? (thread.blocks[at] as TextBlock) : undefined;
    const text = asString((content as { text?: string }).text) ?? "";
    return putBlock(thread, at, mergeTextBlock(existing, key, messageId, text, uuid));
  }
  if (content.type === "thinking") {
    const key = `${thread.toolUseId}|${messageId}|think|${uuid ?? thread.blocks.length}`;
    const at = indexOfKey(thread.blocks, key);
    const existing = at >= 0 ? (thread.blocks[at] as ThinkingBlock) : undefined;
    const text = asString((content as { thinking?: string }).thinking) ?? "";
    const signature = asString((content as { signature?: string }).signature);
    return putBlock(
      thread,
      at,
      mergeThinkingBlock(existing, key, messageId, text, signature, uuid, nowMs, 0)
    );
  }
  if (content.type === "tool_use") {
    const tool = content as { id: string; name: string; input?: JsonObject };
    const at = indexOfTool(thread.blocks, tool.id);
    const existing = at >= 0 ? (thread.blocks[at] as ToolBlock) : undefined;
    const key = existing?.key ?? `${thread.toolUseId}|tool|${tool.id}`;
    return putBlock(
      thread,
      at,
      mergeToolUseBlock(existing, key, messageId, tool, uuid, nowMs)
    );
  }
  return thread;
}

/**
 * A forwarded user frame. Two shapes matter:
 *  - a `text` block, which for an agent's FIRST frame is its own prompt and
 *    later is a mailbox delivery (the relay path's landing point); and
 *  - a `tool_result`, which settles a tool block already in the thread.
 */
export function applyUserToThread(
  model: TranscriptModel,
  line: UserLine,
  parentToolUseId: string,
  nowMs: number
): TranscriptModel {
  const ensured = ensureThread(model, parentToolUseId, nowMs);
  let next = ensured.model;
  let thread: AgentThread = takeLiveOver(ensured.thread);
  const content = line.message.content;
  const subagentType = asString((line as unknown as JsonObject).subagent_type);
  const description = asString((line as unknown as JsonObject).task_description);
  thread = {
    ...thread,
    subagentType: thread.subagentType ?? subagentType,
    description: thread.description ?? description
  };

  if (typeof content === "string") {
    next = markRelaysDelivered(next, parentToolUseId, content);
    return writeThread(next, appendUserText(thread, content, line.uuid));
  }
  for (const item of content ?? []) {
    if (item.type === "text") {
      const text = asString((item as { text?: string }).text) ?? "";
      next = markRelaysDelivered(next, parentToolUseId, text);
      thread = appendUserText(thread, text, line.uuid);
      continue;
    }
    if (item.type === "tool_result") {
      const result = item as { tool_use_id: string; content?: unknown; is_error?: boolean };
      thread = settleThreadTool(
        thread,
        result.tool_use_id,
        result,
        line.tool_use_result,
        nowMs
      );
    }
  }
  return writeThread(next, thread);
}

/**
 * A user-side message in an agent's thread. The first one is the agent's own
 * prompt; every later one is something delivered to it mid-run — the relay's
 * mailbox drop, which the agent view has to show as the user's message, not as
 * an anonymous notice.
 *
 * A delivery that matches a message the composer already showed optimistically
 * CONFIRMS that one in place rather than adding a second copy: the user typed
 * it once, and the round trip through main is plumbing, not a second event.
 */
function appendUserText(thread: AgentThread, text: string, uuid: string | undefined): AgentThread {
  if (text.trim().length === 0) return thread;
  const key = `${thread.toolUseId}|user|${uuid ?? thread.blocks.length}`;
  if (indexOfKey(thread.blocks, key) >= 0) return thread;
  const pendingAt = indexOfPendingMatch(thread.blocks, text);
  if (pendingAt >= 0) {
    const existing = thread.blocks[pendingAt] as UserTextBlock;
    return putBlock(thread, pendingAt, { ...existing, pending: undefined, uuid: uuid ?? existing.uuid });
  }
  const block: Block = {
    kind: "userText",
    key,
    uuid,
    text,
    // The opening frame of a thread IS the prompt the parent wrote for it, and
    // it reads very differently from a message sent to a running agent.
    prompt: thread.blocks.length === 0
  };
  return { ...thread, blocks: thread.blocks.concat(block) };
}

/**
 * A pending relay whose text the delivery contains.
 *
 * `includes` rather than equality on purpose: the CLI wraps a mailbox drop in
 * its own framing ("Message from the lead agent: …"), so the delivered text is
 * the user's message plus context. An exact match would draw the message twice
 * — once pending forever, once delivered.
 */
function indexOfPendingMatch(blocks: Block[], text: string): number {
  const needle = text.trim();
  if (needle.length === 0) return -1;
  for (let i = blocks.length - 1; i >= 0; i -= 1) {
    const block = blocks[i];
    if (block.kind !== "userText" || !block.pending) continue;
    const own = block.text.trim();
    if (needle.includes(own) || own.includes(needle)) return i;
  }
  return -1;
}

/**
 * Show a relayed message in the agent's thread the moment it is sent.
 *
 * The real delivery is several seconds away — main has to take a turn, call
 * SendMessage, and the agent only reads its mailbox at its next tool round — and
 * a composer that swallows what you typed until then reads as a send that
 * failed. The block is marked `pending` and confirmed by the delivery.
 */
export function appendPendingRelay(
  model: TranscriptModel,
  toolUseId: string,
  uuid: string,
  text: string,
  nowMs: number
): TranscriptModel {
  const ensured = ensureThread(model, toolUseId, nowMs);
  const thread = ensured.thread;
  const key = `${toolUseId}|relay|${uuid}`;
  if (indexOfKey(thread.blocks, key) >= 0) return ensured.model;
  const block: Block = { kind: "userText", key, uuid, text, pending: true };
  return writeThread(ensured.model, { ...thread, blocks: thread.blocks.concat(block) });
}

/**
 * Fold a disk-replayed transcript into a thread that has no live frames.
 *
 * `blocks` come from an isolated replay of the agent's own session file, which
 * is the same shape the live path produces — so the agent view renders both
 * with one set of renderers and cannot tell the reader a different story
 * depending on where the frames came from.
 */
export function hydrateThread(
  model: TranscriptModel,
  toolUseId: string,
  blocks: Block[],
  nowMs: number
): TranscriptModel {
  const ensured = ensureThread(model, toolUseId, nowMs);
  const thread = ensured.thread;
  if (thread.hasLiveFrames || thread.hydratedFromDisk) return ensured.model;
  return writeThread(ensured.model, { ...thread, blocks, hydratedFromDisk: true });
}

/**
 * A relay has reached the agent when a user-side message carrying its text shows
 * up in the forwarded thread.
 */
export function markRelaysDelivered(
  model: TranscriptModel,
  toolUseId: string,
  text: string
): TranscriptModel {
  const needle = text.trim();
  if (needle.length === 0) return model;
  let relays = model.relays;
  let changed = false;
  for (const [uuid, relay] of Object.entries(model.relays)) {
    if (relay.toolUseId !== toolUseId || relay.state === "delivered") continue;
    const own = relay.text.trim();
    if (!needle.includes(own) && !own.includes(needle)) continue;
    if (!changed) relays = { ...relays };
    relays[uuid] = { ...relay, state: "delivered" };
    changed = true;
  }
  return changed ? { ...model, relays, revision: model.revision + 1 } : model;
}

function settleThreadTool(
  thread: AgentThread,
  toolUseId: string,
  result: { content?: unknown; is_error?: boolean },
  structured: JsonObject | undefined,
  nowMs: number
): AgentThread {
  const at = indexOfTool(thread.blocks, toolUseId);
  if (at < 0) return thread;
  const block = thread.blocks[at] as ToolBlock;
  const text = stringifyResult(result.content);
  const status = classifyToolStatus(block.name, result.is_error === true, text, structured);
  const payload = normalizeToolResultPayload(text, structured);
  const next: ToolBlock = {
    ...block,
    status,
    streaming: false,
    inputComplete: true,
    resultText: text,
    resultIsError: result.is_error === true,
    resultTextSources: payload.resultTextSources,
    structured: payload.structured,
    endedAtMs: nowMs
  };
  return putBlock(thread, at, next);
}

function stringifyResult(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (typeof part === "string") return part;
        if (isPlainObject(part) && typeof part.text === "string") return part.text;
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  if (content === undefined || content === null) return "";
  return JSON.stringify(content, null, 2);
}

/**
 * Task frames enrich thread META by tool_use_id: status, live activity, the
 * usage tallies the dock's right column shows.
 *
 * A `local_agent` task MAY open its thread; nothing else may. That distinction
 * is the whole rule — `task_started` fires for foreground Bash too, and a dock
 * listing every shell as an agent would be the tasks-strip bug in a new place —
 * and `task_type` says which is which on the frame itself (`local_bash` for
 * every shell, including the ones a subagent owns).
 *
 * Opening it here matters because the two announcements race. A NESTED agent's
 * `task_started` arrives BEFORE the `assistant` frame carrying its Agent
 * tool_use (probed in fwd2.jsonl: task_started at line 37, the tool_use at 38),
 * so a rule that only ever enriched an existing thread dropped that frame — and
 * with it the only copy of the agent's prompt that is always on the wire. The
 * parent link is left for the tool_use frame to supply, which `ensureThread`
 * already handles by adopting a thread that was created without one.
 */
export function applyTaskToThread(
  model: TranscriptModel,
  toolUseId: string | undefined,
  record: TaskRecord | undefined,
  nowMs: number
): TranscriptModel {
  if (!toolUseId || !record) return model;
  if (record.taskType !== undefined && record.taskType !== "local_agent") return model;
  let existing = model.agentThreads[toolUseId];
  let next = model;
  if (!existing) {
    if (record.taskType !== "local_agent") return model;
    const ensured = ensureThread(model, toolUseId, record.startedAtMs ?? nowMs);
    next = ensured.model;
    existing = ensured.thread;
  }
  model = next;
  const settled =
    record.status === "completed" ||
    record.status === "failed" ||
    record.status === "killed" ||
    record.status === "stopped";
  return writeThread(model, {
    ...existing,
    taskId: record.taskId ?? existing.taskId,
    description: existing.description ?? record.description,
    subagentType: existing.subagentType ?? record.subagentType,
    // The one prompt source that is ALWAYS there. The forwarded first user
    // frame carries it too, but only while forwarding is on and only for an
    // agent whose thread started in this pane — which is why an agent opened
    // from a background launch, or any agent in the relay probe, had a view
    // with no brief at the top while its sibling had one.
    prompt: existing.prompt ?? record.prompt,
    status: record.status ?? existing.status,
    activity: record.activity ?? existing.activity,
    lastToolName: record.lastToolName ?? existing.lastToolName,
    summary: record.summary ?? existing.summary,
    totalTokens: record.totalTokens ?? existing.totalTokens,
    toolUses: record.toolUses ?? existing.toolUses,
    durationMs: record.durationMs ?? existing.durationMs,
    background: record.isBackgrounded ?? existing.background,
    // ONE clock: the dock row and the inline row describe the same agent, and
    // the task record's start is what the tasks strip already counts from.
    startedAtMs: record.startedAtMs ?? existing.startedAtMs,
    endedAtMs: settled ? record.endedAtMs ?? existing.endedAtMs ?? nowMs : existing.endedAtMs
  });
}

/**
 * What the launching turn learned from the Agent tool_result — model, agentId,
 * the final tallies. The tool_result lands in the MAIN turn (parent null), so
 * this is how a thread gets its outcome when no task frame carried it.
 */
export function applyAgentOutputToThread(
  model: TranscriptModel,
  toolUseId: string,
  structured: JsonObject | undefined,
  toolStatus: ToolStatus,
  nowMs: number
): TranscriptModel {
  const existing = model.agentThreads[toolUseId];
  if (!existing) return model;
  const structuredStatus = asString(structured?.status);
  const status =
    structuredStatus === "completed" || structuredStatus === "success"
      ? "completed"
      : structuredStatus === "failed" || structuredStatus === "error"
        ? "failed"
        : structuredStatus === "killed"
          ? "killed"
          : structuredStatus === "stopped" || structuredStatus === "aborted"
            ? "stopped"
            : toolStatus === "error"
              ? "failed"
              : toolStatus === "aborted"
                ? "stopped"
                : existing.status;
  const done =
    status === "completed" ||
    status === "failed" ||
    status === "killed" ||
    status === "stopped";
  const raw = isPlainObject(structured?.toolStats) ? structured.toolStats : undefined;
  return writeThread(model, {
    ...existing,
    toolStats: raw
      ? {
          readCount: asNumber(raw.readCount),
          searchCount: asNumber(raw.searchCount),
          bashCount: asNumber(raw.bashCount),
          editFileCount: asNumber(raw.editFileCount),
          linesAdded: asNumber(raw.linesAdded),
          linesRemoved: asNumber(raw.linesRemoved),
          otherToolCount: asNumber(raw.otherToolCount)
        }
      : existing.toolStats,
    agentId: asString(structured?.agentId) ?? existing.agentId,
    taskId: existing.taskId ?? asString(structured?.agentId),
    subagentType: existing.subagentType ?? asString(structured?.agentType),
    model: asString(structured?.resolvedModel) ?? existing.model,
    totalTokens: asNumber(structured?.totalTokens) ?? existing.totalTokens,
    toolUses: asNumber(structured?.totalToolUseCount) ?? existing.toolUses,
    durationMs: asNumber(structured?.totalDurationMs) ?? existing.durationMs,
    background: structuredStatus === "async_launched" ? true : existing.background,
    status: done ? status : existing.status,
    endedAtMs: done ? existing.endedAtMs ?? nowMs : existing.endedAtMs
  });
}

/** The stable user-facing identity used to associate separate retry calls. */
function retryDescription(block: ToolBlock): string | undefined {
  if (!isTaskTool(block.name)) return undefined;
  const description =
    block.subagent?.description ??
    (typeof block.input.description === "string" ? block.input.description : undefined);
  const trimmed = description?.trim();
  return trimmed ? trimmed : undefined;
}

function agentAttemptOutcome(
  model: Pick<TranscriptModel, "agentThreads">,
  block: ToolBlock
): "failed" | "completed" | undefined {
  const threadStatus = model.agentThreads[block.toolUseId]?.status;
  const taskStatus = block.subagent?.status;
  const structuredStatus = asString(block.structured?.status);
  if (
    block.status === "error" ||
    threadStatus === "failed" ||
    taskStatus === "failed" ||
    structuredStatus === "failed" ||
    structuredStatus === "error"
  ) {
    return "failed";
  }
  if (
    threadStatus === "completed" ||
    taskStatus === "completed" ||
    structuredStatus === "completed"
  ) {
    return "completed";
  }
  return undefined;
}

/**
 * Mark failed Agent/Task siblings that a later successful retry replaced.
 *
 * Retries are separate tool_use ids, so without this relation the transcript
 * presents one logical job as two peer agents: "Failed" and then "Done". The
 * failed attempt is retained in the reducer for auditability and is marked only
 * after a later sibling with the same non-empty description actually completes.
 * Killed/stopped attempts are not failures and are never folded by this rule.
 */
export function reconcileSupersededAgentAttempts(model: TranscriptModel): TranscriptModel {
  let threads = model.agentThreads;
  let threadsChanged = false;

  const markThread = (failedToolUseId: string, retryToolUseId: string) => {
    const thread = threads[failedToolUseId];
    if (!thread || thread.supersededByToolUseId === retryToolUseId) return;
    if (!threadsChanged) threads = { ...threads };
    threads[failedToolUseId] = {
      ...thread,
      supersededByToolUseId: retryToolUseId,
      revision: thread.revision + 1
    };
    threadsChanged = true;
  };

  const reconcileBlocks = (blocks: Block[]): Block[] => {
    let next = blocks;
    let changed = false;
    const write = (index: number, block: Block) => {
      if (!changed) next = blocks.slice();
      next[index] = block;
      changed = true;
    };

    // Retry attempts can be nested under another agent. Reconcile each sibling
    // list independently so two unrelated parents that chose the same generic
    // description never hide one another's work.
    for (let index = 0; index < blocks.length; index += 1) {
      const block = next[index];
      if (block.kind !== "tool" || block.children.length === 0) continue;
      const children = reconcileBlocks(block.children);
      if (children !== block.children) write(index, { ...block, children });
    }

    const nearestLaterSuccess = new Map<string, string>();
    for (let index = next.length - 1; index >= 0; index -= 1) {
      const block = next[index];
      if (block.kind !== "tool") continue;
      const description = retryDescription(block);
      if (!description) continue;
      const outcome = agentAttemptOutcome(model, block);
      if (outcome === "completed") {
        nearestLaterSuccess.set(description, block.toolUseId);
        continue;
      }
      if (outcome !== "failed") continue;
      const retryToolUseId = nearestLaterSuccess.get(description);
      if (!retryToolUseId) continue;
      if (block.supersededByToolUseId !== retryToolUseId) {
        write(index, { ...block, supersededByToolUseId: retryToolUseId });
      }
      markThread(block.toolUseId, retryToolUseId);
    }
    return changed ? next : blocks;
  };

  let turnsChanged = false;
  const turns = model.turns.map((turn) => {
    const blocks = reconcileBlocks(turn.blocks);
    if (blocks === turn.blocks) return turn;
    turnsChanged = true;
    return { ...turn, blocks, revision: turn.revision + 1 };
  });

  // Forwarded frames also live in their parent's drill-in thread. Keep that
  // second projection coherent with the inline tree so a nested retry can be
  // collapsed in both places from the same field.
  for (const toolUseId of Object.keys(threads)) {
    const before = threads[toolUseId];
    const blocks = reconcileBlocks(before.blocks);
    if (blocks === before.blocks) continue;
    if (!threadsChanged) threads = { ...threads };
    const current = threads[toolUseId];
    threads[toolUseId] = {
      ...current,
      blocks,
      revision: current.revision + 1
    };
    threadsChanged = true;
  }

  if (!turnsChanged && !threadsChanged) return model;
  return {
    ...model,
    turns: turnsChanged ? turns : model.turns,
    agentThreads: threadsChanged ? threads : model.agentThreads,
    revision: model.revision + 1
  };
}

/**
 * Agent spawns announced on a MAIN-thread assistant frame.
 *
 * The top-level Agent tool_use arrives with `parent_tool_use_id: null` — it is
 * main talking — so the nested path above never sees it, and without this the
 * dock would list only the agents that agents spawned. Same rule, one level up:
 * the tool_use id IS the thread id.
 */
export function registerRootSpawns(
  model: TranscriptModel,
  content: ContentBlock[] | undefined,
  nowMs: number
): TranscriptModel {
  let next = model;
  for (const item of content ?? []) {
    if (item.type !== "tool_use") continue;
    const tool = item as { id: string; name: string; input?: JsonObject };
    if (!isTaskTool(tool.name)) continue;
    const ensured = ensureThread(next, tool.id, nowMs);
    next = writeThread(ensured.model, {
      ...ensured.model.agentThreads[tool.id],
      description: asString(tool.input?.description) ?? ensured.thread.description,
      subagentType: asString(tool.input?.subagent_type) ?? ensured.thread.subagentType
    });
  }
  return next;
}

/** Depth-first order with depth, which is exactly how the dock lists agents. */
export function flattenThreads(
  model: Pick<TranscriptModel, "agentThreads" | "agentRootIds">
): { thread: AgentThread; depth: number }[] {
  const out: { thread: AgentThread; depth: number }[] = [];
  const seen = new Set<string>();
  const walk = (id: string, depth: number) => {
    if (seen.has(id)) return;
    seen.add(id);
    const thread = model.agentThreads[id];
    if (!thread) return;
    out.push({ thread, depth });
    for (const child of thread.childIds) walk(child, depth + 1);
  };
  for (const id of model.agentRootIds) walk(id, 0);
  // A thread whose parent never registered it still belongs on the dock: losing
  // an agent because one frame arrived out of order is worse than an odd indent.
  for (const id of Object.keys(model.agentThreads)) walk(id, 0);
  return out;
}

export function isThreadRunning(thread: AgentThread): boolean {
  return (
    thread.status !== "completed" &&
    thread.status !== "failed" &&
    thread.status !== "killed" &&
    thread.status !== "stopped"
  );
}

/**
 * The blocks an agent view renders: the thread's own, with its brief guaranteed
 * to be the first of them.
 *
 * The prompt reaches the pane by three routes and no single one covers every
 * agent. `task_started.prompt` is present for every `local_agent` but for no
 * workflow agent; the first forwarded `user` frame is present only while
 * `forwardSubagentText` is on and the agent is live; a disk replay has it only
 * once the file exists. Reading one route was why the prompt showed on some
 * subagents and not others.
 *
 * So the fallbacks are resolved in ONE place rather than in each view: whatever
 * the thread already opens with wins (that is the real frame, with its uuid and
 * its exact text), and `task_started.prompt` fills the gap when it does not.
 * The synthesized block is deliberately keyed off the thread id so it is stable
 * across re-renders and cannot collide with a real frame's key.
 */
export function threadBlocks(thread: AgentThread): Block[] {
  const first = thread.blocks[0];
  if (first?.kind === "userText" && first.prompt) return thread.blocks;
  const prompt = thread.prompt?.trim();
  if (!prompt) return thread.blocks;
  // A live prompt frame may still be somewhere in the thread even when it is
  // not first (a tool_result can land ahead of it on a resumed thread); showing
  // the brief twice is worse than showing it once in the wrong place.
  if (thread.blocks.some((block) => block.kind === "userText" && block.text.trim() === prompt)) {
    return thread.blocks;
  }
  const block: Block = {
    kind: "userText",
    key: `${thread.toolUseId}|prompt`,
    text: prompt,
    prompt: true
  };
  return [block, ...thread.blocks];
}

export { MAIN as MAIN_THREAD_ID };

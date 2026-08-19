import type {
  CanUseToolRequest,
  ContextUsage,
  EffortLevel,
  JsonObject,
  McpServerDescriptor,
  ModelDescriptor,
  PermissionMode,
  ProtocolLine,
  SessionState,
  SlashCommandDescriptor,
  TodoItem
} from "../protocol/types";

export interface ImageAttachment {
  mediaType: string;
  dataBase64: string;
  name?: string;
}

export interface TextBlock {
  kind: "text";
  key: string;
  messageId: string;
  uuid?: string;
  text: string;
  streaming: boolean;
  aborted?: boolean;
}

export interface ThinkingBlock {
  kind: "thinking";
  key: string;
  messageId: string;
  uuid?: string;
  text: string;
  signature?: string;
  tokens: number;
  streaming: boolean;
  startedAtMs: number;
  endedAtMs?: number;
  aborted?: boolean;
}

export type ToolStatus = "pending" | "running" | "success" | "error" | "denied" | "aborted";

/** `AgentOutput.toolStats` — what the agent actually did, once it is done. */
export interface SubagentToolStats {
  readCount?: number;
  searchCount?: number;
  bashCount?: number;
  editFileCount?: number;
  linesAdded?: number;
  linesRemoved?: number;
  otherToolCount?: number;
}

export interface SubagentInfo {
  taskId?: string;
  /** `local_agent` | `local_bash` | `local_workflow`, straight off the wire. */
  taskType?: string;
  subagentType?: string;
  description?: string;
  status?: string;
  lastToolName?: string;
  activity?: string;
  summary?: string;
  outputFile?: string;
  totalTokens?: number;
  toolUses?: number;
  durationMs?: number;
  workflowName?: string;
  /** `wf_…`, from the launching tool_use_result — the drill-in key. */
  workflowRunId?: string;
  /** `resolvedModel` from AgentOutput, for the model chip. */
  model?: string;
  /** AgentOutput.agentId — a stable id even before the task frames land. */
  agentId?: string;
  /** AgentOutput.toolStats, for the completed "read 12 · edited 3 · +40 −7" row. */
  toolStats?: SubagentToolStats;
  /** BashOutput.backgroundedByUser — the ctrl+B path, not run_in_background. */
  backgroundedByUser?: boolean;
  /** BashOutput.timedOutAfterMs — the CLI auto-backgrounded on timeout. */
  timedOutAfterMs?: number;
  /**
   * The task is in (or has been in) the CLI's background set. A foreground Bash
   * also gets a task_id, so this — not the presence of a task — is what makes a
   * card a background card.
   */
  background?: boolean;
  /**
   * Bumped on every task frame for this id, so a drill-in that is open while the
   * agent still runs has something to re-fetch on.
   */
  progressTick?: number;
  /**
   * The TASK's start, copied off its record. The card and the strip row describe
   * the same running command, so they must count from the same instant: the
   * block's own `startedAtMs` is when the tool_use block was built, which drifts
   * from the record's by however long the CLI took to announce the task, and the
   * two clocks then disagree by a second or two forever.
   */
  startedAtMs?: number;
}

export type WorkflowAgentState =
  | "queued"
  | "running"
  | "done"
  | "error"
  | "blocked"
  | "cached";

export interface WorkflowPhase {
  index: number;
  title: string;
  kind?: string;
}

export interface WorkflowAgent {
  index: number;
  label: string;
  phaseIndex?: number;
  phaseTitle?: string;
  agentId?: string;
  agentType?: string;
  isolation?: string;
  model?: string;
  fallbackModel?: string;
  /**
   * The display state. The wire only says start | done | error; queued is a
   * `start` that has no `startedAt` yet, and blocked/cached are flags the CLI
   * sets alongside it. Collapsing them here keeps one chip per row rather than
   * making every renderer re-derive the same precedence.
   */
  state: WorkflowAgentState;
  wireState?: string;
  queuedAt?: number;
  startedAt?: number;
  lastProgressAt?: number;
  attempt?: number;
  lastAttemptReason?: string;
  lastToolName?: string;
  lastToolSummary?: string;
  promptPreview?: string;
  tokens?: number;
  toolCalls?: number;
  durationMs?: number;
  resultPreview?: string;
  error?: string;
  blocked?: boolean;
  cached?: boolean;
}

export interface WorkflowTotals {
  agents: number;
  done: number;
  running: number;
  failed: number;
  tokens: number;
  toolCalls: number;
}

/**
 * A `workflow_progress` array folded into something renderable. The wire sends a
 * cumulative list of items keyed by `(type, index)` which are REPLACED in place
 * as agents advance, so each list keeps its arrival order and an upsert can
 * never reorder a phase or an agent under the reader.
 */
export interface WorkflowProgress {
  name?: string;
  runId?: string;
  status?: string;
  phases: WorkflowPhase[];
  agents: WorkflowAgent[];
  logs: string[];
  totals: WorkflowTotals;
}

export interface ToolBlock {
  kind: "tool";
  key: string;
  messageId: string;
  uuid?: string;
  toolUseId: string;
  name: string;
  input: JsonObject;
  partialInput?: string;
  inputComplete: boolean;
  status: ToolStatus;
  streaming: boolean;
  resultText?: string;
  resultIsError?: boolean;
  structured?: JsonObject;
  startedAtMs: number;
  endedAtMs?: number;
  children: Block[];
  subagent?: SubagentInfo;
  /** Present only on a Workflow tool block that has reported progress. */
  workflow?: WorkflowProgress;
  /**
   * A later sibling Agent/Task with the same description completed successfully.
   * The failed attempt remains in the model for honesty/auditability, while the
   * transcript may collapse it instead of presenting a retry as distinct work.
   */
  supersededByToolUseId?: string;
  aborted?: boolean;
}

export interface DividerBlock {
  kind: "divider";
  key: string;
  variant: "compact" | "reset" | "continued";
  trigger?: string;
  preTokens?: number;
}

/**
 * The output of a LOCAL slash command — the text inside a
 * `<local-command-stdout>` transcript record, or a `local_command_output`
 * system frame. It is neither the user speaking nor Claude answering, so it
 * renders as a dim one-line result under the command chip, never as a bubble.
 */
export interface CommandOutputBlock {
  kind: "commandOutput";
  key: string;
  text: string;
}

/** Classified model errors the CLI reports, so the view can title them. */
export type NoticeErrorKind = "auth" | "billing" | "rateLimit" | "generic";

export interface NoticeBlock {
  kind: "notice";
  key: string;
  level: "info" | "warning" | "error";
  title?: string;
  errorKind?: NoticeErrorKind;
  text: string;
}

export interface ImageBlock {
  kind: "image";
  key: string;
  mediaType: string;
  dataBase64: string;
}

/**
 * A user-side message INSIDE an agent thread.
 *
 * A turn carries its user text on the turn itself, so the main chat never
 * needed this. An agent thread has no turns — it is one flat conversation — and
 * two different things arrive on its user side: the prompt the parent wrote for
 * it (frame one), and anything delivered to it mid-run through the mailbox,
 * which is where a relayed message lands. Rendering both as an anonymous
 * `notice` — what round 3 did — hid the fact that the user had spoken to the
 * agent at all.
 */
export interface UserTextBlock {
  kind: "userText";
  key: string;
  uuid?: string;
  text: string;
  /** The agent's opening prompt, rather than a message sent to it later. */
  prompt?: boolean;
  /**
   * Shown optimistically: the composer sent it, and the forwarded thread has not
   * echoed it back yet. Cleared when the real delivery arrives.
   */
  pending?: boolean;
  /**
   * A MAIN-transcript message the user queued while the turn ran, which the
   * CLI consumed mid-turn (its `command_lifecycle` frame said "started" while
   * the turn was still streaming). It renders as a user bubble inside the turn
   * it interjected into — the CLI answered it there, so drawing it as its own
   * later turn would show a question the transcript already answered.
   */
  interjection?: boolean;
  /** Attachments the interjected message carried. */
  images?: ImageAttachment[];
}

export type Block =
  | TextBlock
  | ThinkingBlock
  | ToolBlock
  | DividerBlock
  | NoticeBlock
  | ImageBlock
  | UserTextBlock
  | CommandOutputBlock;

export type TurnState = "queued" | "streaming" | "complete" | "aborted" | "error";

export interface TurnResult {
  subtype: string;
  isError: boolean;
  text?: string;
  durationMs?: number;
  numTurns?: number;
  /** The CLI's running session total at this result (`total_cost_usd`). */
  totalCostUsd?: number;
  /** What THIS turn added to that total. */
  costDeltaUsd?: number;
  terminalReason?: string;
  inputTokens?: number;
  outputTokens?: number;
  thinkingTokens?: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
}

export interface Turn {
  id: string;
  seq: number;
  userText?: string;
  userImages?: ImageAttachment[];
  userUuid?: string;
  /**
   * This turn is a LOCAL slash command (`/model opus`), reconstructed from the
   * CLI's `<command-name>/<command-args>` transcript records. It renders as a
   * quiet command chip rather than a user bubble — the user issued a command,
   * they did not say these words to Claude.
   */
  command?: { name: string; args?: string };
  startedAtMs: number;
  endedAtMs?: number;
  /**
   * When the turn last received a frame. Replayed history has no `result`
   * frames, so its turns are closed at a process boundary long after the fact;
   * settling them at "now" would report a two-day "Worked for". The last
   * frame's own time is the honest end.
   */
  lastFrameAtMs?: number;
  state: TurnState;
  blocks: Block[];
  result?: TurnResult;
  errorText?: string;
  folded: boolean;
  /**
   * The `result` wanted to fold this turn and could not: it still owned a
   * background task that was running. The fold is honoured when that task
   * settles, and dropped the moment the user folds or unfolds by hand — a turn
   * that collapses under the reader while they are reading it is worse than one
   * that stays open.
   */
  foldWhenTasksSettle?: boolean;
  /**
   * The user folded or unfolded this turn BY HAND, and that choice outranks
   * every automatic fold. A turn the user opened stays open through a reopen
   * (the CLI's post-result summary leg merging back in) and through the merged
   * turn's own later result — collapsing it under them would undo an explicit
   * act as the acknowledgement of finishing.
   */
  foldOverride?: boolean;
  revision: number;
}

export type PendingKind = "permission" | "question" | "plan" | "enterPlan";

export interface PendingPermission {
  requestId: string;
  kind: PendingKind;
  request: CanUseToolRequest;
  receivedAtMs: number;
}

/**
 * A message the composer sent to MAIN in order to reach a subagent.
 *
 * There is no wire subtype that prompts a running agent directly (round-4
 * probe: an outbound user frame carrying `parent_tool_use_id` is ignored as
 * targeting and lands in main's queue), so the only route is to ask main to
 * pass it on with SendMessage. That makes one user act into two facts — a main
 * turn that must not read as the user talking to Claude, and a message the
 * AGENT view has to show as the user's own — which is why the target rides on
 * the message rather than being re-derived later from the text.
 */
export interface RelayTarget {
  /** The agent thread this message is FOR. */
  toolUseId: string;
  /** Its description, for the chip: "→ sent to Slow summarizer". */
  description?: string;
}

export type RelayState = "sending" | "relayed" | "delivered" | "failed";

export interface RelayRecord {
  uuid: string;
  toolUseId: string;
  text: string;
  description?: string;
  sentAtMs: number;
  /**
   * `sending` until main answers, `relayed` once the turn carrying the request
   * settles (main ran SendMessage and said RELAYED), `delivered` when the agent
   * itself shows a user-side message afterwards — the mailbox drop landing at
   * its next tool round. Distinct states because they are genuinely different
   * news: relayed means main did its part, delivered means the agent has it.
   * `failed` is the turn erroring or being interrupted before either — the one
   * outcome where the message did NOT arrive and the user must be told.
   */
  state: RelayState;
  /** The agent was backgrounded first so main could act on the relay. */
  backgrounded?: boolean;
}

export interface QueuedMessage {
  uuid: string;
  text: string;
  images?: ImageAttachment[];
  queuedAtMs: number;
  /** Set when this message is a relay: it is addressed to an agent, not to main. */
  relay?: RelayTarget;
}

export interface SessionMeta {
  sessionId?: string;
  cwd?: string;
  model?: string;
  modelDisplayName?: string;
  /**
   * The EXPLICIT effort selection — a picker click, a wheel step, or a level
   * adopted from a resumed session's own records. `undefined` does not mean "no
   * reasoning": the CLI then runs at a default, and every display surface goes
   * through `effectiveEffort` so a selected level is always shown.
   */
  effort?: EffortLevel;
  /**
   * A user pick the WIRE has not yet confirmed. Set when the picker (not a
   * snapshot bootstrap) writes `model`; cleared when a wire frame (init,
   * message_start) reports the same model, or when the conversation resets.
   * While set, a wire frame reporting a DIFFERENT model is ignored for
   * `session.model`: it describes the state the pick is about to change — the
   * in-flight turn's message_start, or the init of a restart whose params were
   * built before the pick — and adopting it silently reverted the picker to
   * the settings default ("stays on GPT 5.6 Sol no matter what I pick").
   */
  modelPickPending?: boolean;
  /**
   * The pane-level default model, delivered in `harness.context`: the
   * machine-wide LAST-USED model when one has been recorded (any harness pane
   * starting with a model, a set_model ack, an init frame), else the CLI's
   * settings-file default (`~/.claude/settings.json` "model", project files
   * first). It is what the trigger names on a fresh pane instead of the
   * catalog's generic "Default (recommended)" row while nothing stronger (init
   * frame, user pick, restore snapshot, replayed history) exists. Weakest
   * source: any of those overwrite it.
   */
  defaultModel?: string;
  /**
   * The CLI's settings default for reasoning effort (`effortLevel`). The live
   * catalog ships NO per-model `defaultEffortLevel`, so without this the pane
   * cannot say which level an un-picked session actually runs at.
   */
  defaultEffort?: EffortLevel;
  permissionMode: PermissionMode;
  tools: string[];
  slashCommands: string[];
  commands: SlashCommandDescriptor[];
  models: ModelDescriptor[];
  agents: string[];
  skills: string[];
  mcpServers: McpServerDescriptor[];
  cliVersion?: string;
  capabilities: string[];
  outputStyle?: string;
  title?: string;
}

export interface UsageTotals {
  costUsd: number;
  inputTokens: number;
  outputTokens: number;
  thinkingTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  turns: number;
}

export type RunPhase = "idle" | "starting" | "running" | "exited";

export interface ActivityState {
  sessionState: SessionState;
  status: "requesting" | "compacting" | null;
  thinkingTokens: number;
  liveToolName?: string;
  liveToolStartedAtMs?: number;
}

export interface Banner {
  id: string;
  severity: "info" | "warning" | "error";
  title: string;
  detail?: string;
  /**
   * A catalog key for the title, when the REDUCER is the thing that knows what
   * happened. `title` then carries the subject the key interpolates — a task
   * description, a workflow name. Most banners come off the wire already
   * phrased, and those set `title` alone.
   */
  titleKey?: string;
  createdAtMs: number;
  retry?: { attempt: number; maxRetries?: number; retryDelayMs?: number };
}

/**
 * A row of the tasks strip. Membership comes from `background_tasks_changed`
 * ONLY (REPLACE semantics) — a foreground Bash gets a task_id too, so task
 * frames may never add a row by themselves. The detail is read from
 * `tasksById`, which is why the strip keeps working when the launching turn is
 * folded, scrolled away, or already settled by its `result`.
 */
export interface BackgroundTask {
  taskId: string;
  taskType?: string;
  description?: string;
  subagentType?: string;
  status?: string;
  totalTokens?: number;
  toolUses?: number;
  durationMs?: number;
}

export type TaskType = "local_bash" | "local_agent" | "local_workflow" | string;

/**
 * Everything the pane knows about one task_id, accumulated across
 * task_started / task_progress / task_updated / task_notification. Kept beside
 * the transcript rather than only on the launching ToolBlock because the strip,
 * the drill-in, and the output tail all outlive the turn that started the task.
 */
export interface TaskRecord {
  taskId: string;
  taskType?: TaskType;
  toolUseId?: string;
  description?: string;
  /** pending | running | completed | failed | killed | paused | stopped. */
  status?: string;
  workflowName?: string;
  workflowRunId?: string;
  subagentType?: string;
  activity?: string;
  lastToolName?: string;
  summary?: string;
  /**
   * The brief the task was launched with (`task_started.prompt`). Present for
   * every `local_agent`, and for a workflow it is the workflow SOURCE rather
   * than an agent's prompt — which is why only the agent threads read it.
   */
  prompt?: string;
  error?: string;
  outputFile?: string;
  totalTokens?: number;
  toolUses?: number;
  durationMs?: number;
  isBackgrounded?: boolean;
  startedAtMs: number;
  endedAtMs?: number;
  /** Incremented on every frame for this task; a drill-in re-fetches on it. */
  progressTick: number;
  workflow?: WorkflowProgress;
}

/**
 * One agent's own conversation, built LIVE from forwarded frames.
 *
 * Round-4 wire fact: with `forwardSubagentText` set, a subagent's text and
 * thinking arrive as ordinary `assistant`/`user` frames whose
 * `parent_tool_use_id` is its IMMEDIATE parent Agent tool_use id. So the whole
 * tree falls out of one rule — thread(X) is every frame with parent X, and an
 * Agent tool_use with id Y inside thread X opens child thread Y — and the main
 * chat is simply the thread whose parent is null.
 *
 * The blocks are the SAME `Block` union the turns carry, so the agent view can
 * render with the main chat's renderers rather than a second, thinner set that
 * drifts from it.
 */
export interface AgentThread {
  toolUseId: string;
  /** The Task input's `description` — the agent's name everywhere it appears. */
  description?: string;
  subagentType?: string;
  taskId?: string;
  /**
   * The brief this agent was given, from `task_started.prompt`.
   *
   * The prompt reaches the pane by up to three routes and only ONE of them is
   * always present. `task_started` carries it in full for every `local_agent`
   * (probed in fwd/fwd2/nested/relay), the first forwarded `user` frame carries
   * it only while `forwardSubagentText` is on and the agent is live, and the
   * disk transcript carries it only once the file exists. A view that read just
   * one of them showed the prompt for some agents and not others — the round-4
   * report. Recorded here so every surface reads the same field.
   */
  prompt?: string;
  /** The wire's task status, or `running` before any task frame lands. */
  status?: string;
  /** Live activity while it runs, from `task_progress`. */
  activity?: string;
  lastToolName?: string;
  summary?: string;
  model?: string;
  agentId?: string;
  totalTokens?: number;
  toolUses?: number;
  durationMs?: number;
  /** AgentOutput.toolStats — what it actually did, once it is done. */
  toolStats?: SubagentToolStats;
  background?: boolean;
  /** Null for the main thread; the parent Agent's tool_use id otherwise. */
  parentToolUseId?: string;
  /** Child threads, in the order their Agent tool_use blocks arrived. */
  childIds: string[];
  blocks: Block[];
  startedAtMs: number;
  endedAtMs?: number;
  /**
   * A disk transcript was replayed into this thread because no live frames ever
   * arrived (a resumed session, or forwarding that started late). Live frames
   * take over: the flag exists so a second replay cannot double the blocks.
   */
  hydratedFromDisk?: boolean;
  /** Live frames have been seen, so a disk replay would be a duplicate. */
  hasLiveFrames?: boolean;
  /** The successful retry that replaced this failed launch, if there is one. */
  supersededByToolUseId?: string;
  revision: number;
}

export interface TranscriptModel {
  generation: number;
  session: SessionMeta;
  turns: Turn[];
  pending: PendingPermission[];
  queued: QueuedMessage[];
  /**
   * Messages that were queued inside a run which then died before answering
   * them. They cannot stay in `queued`, where the next run's first frame would
   * promote them onto the wrong turn, and they must not be silently dropped —
   * the user typed them. The hook re-sends them, in order, once a run is up.
   */
  stranded: QueuedMessage[];
  todos: TodoItem[];
  usage: UsageTotals;
  contextUsage?: ContextUsage;
  activity: ActivityState;
  banners: Banner[];
  backgroundTasks: BackgroundTask[];
  /**
   * Every task the process has told us about, keyed by task_id. Cleared on
   * `runStarted`: the SDK scopes task ids per PROCESS, so ids from a dead run
   * would otherwise enrich rows belonging to a new one.
   */
  tasksById: Record<string, TaskRecord>;
  /**
   * Every agent thread this session has seen, keyed by the Agent tool_use id.
   * Rows PERSIST after completion, like the CLI's dock: an agent that finished
   * two minutes ago is still the thing you want to read.
   */
  agentThreads: Record<string, AgentThread>;
  /** Root threads in spawn order — the dock's top-level agent rows. */
  agentRootIds: string[];
  /** Relayed messages, keyed by the uuid of the main-thread user message. */
  relays: Record<string, RelayRecord>;
  runPhase: RunPhase;
  runId?: string;
  exitError?: string;
  /** The process never started, as opposed to starting and later exiting. */
  startFailed?: boolean;
  /**
   * A catalog pushed by the native side after a background `initialize` probe,
   * for a pane that has never run a process. Kept apart from `session.models`,
   * which describes the LIVE run, so a stale probe can never masquerade as the
   * running session's capabilities.
   */
  cachedModels?: ModelDescriptor[];
  /**
   * The replayed history was cut at the native record limit, so turns older
   * than the first one shown exist on disk but are not in this model.
   */
  historyTruncated?: boolean;
  /**
   * The model that produced the most recent MAIN-thread assistant frame, as the
   * wire reported it (`message.model`, a resolved id). Replayed history carries
   * no init frame — the native mapper only forwards user/assistant records — so
   * this is the one honest answer to "which model was this session actually on"
   * after a resume, and the hook uses it to seed the composer trigger and the
   * restart params before the new process's init frame arrives.
   */
  lastAssistantModel?: string;
  /**
   * The reasoning effort stamped on the most recent MAIN-thread assistant
   * record (`"effort":"xhigh"` on every disk record; live frames may omit it).
   * The companion to `lastAssistantModel` for the same reason: a resumed
   * session's records are the only account of what effort it was actually
   * running, and `historyReplayed` adopts it so the trigger and the restart
   * params do not silently fall back to a default the session was not on.
   */
  lastAssistantEffort?: EffortLevel;
  stderrTail: string[];
  revision: number;
}

export type LocalAction =
  | {
      kind: "localSend";
      uuid: string;
      text: string;
      images?: ImageAttachment[];
      atMs: number;
      /** Present when the composer was inside an agent view: this is a relay. */
      relay?: RelayTarget;
      /** The relay backgrounded the agent's Task first, so main could act. */
      backgrounded?: boolean;
    }
  /**
   * A disk transcript, replayed into a thread that never received live frames.
   * The events are already parsed protocol lines, so the SAME reducer path that
   * builds a live thread builds this one.
   */
  | { kind: "hydrateThread"; toolUseId: string; events: ProtocolLine[] }
  | { kind: "cancelQueued"; uuid: string }
  /** Interrupt-with-cancel drops the whole queue on the CLI side; mirror it. */
  | { kind: "clearQueued" }
  /** The hook has taken the stranded messages and is re-sending them. */
  | { kind: "takeStranded" }
  | {
      kind: "permissionResolved";
      requestId: string;
      behavior?: "allow" | "deny";
      /** What was sent back, so an answered question can be recorded verbatim. */
      updatedInput?: JsonObject;
    }
  | { kind: "contextUsage"; usage: ContextUsage }
  | { kind: "setTitle"; title: string }
  /**
   * `pick` marks a USER's choice from the model menu (or effort dial), as
   * opposed to a bootstrap projection of a restore snapshot. Only a pick sets
   * `session.modelPickPending`, the latch that stops in-flight wire frames
   * from reverting the menu to the model the process was launched with.
   */
  | { kind: "setModel"; model: string; effort?: EffortLevel; pick?: boolean }
  | { kind: "setPermissionMode"; mode: PermissionMode }
  | { kind: "startFailed"; error?: string }
  | { kind: "dismissBanner"; id: string }
  | { kind: "toggleFold"; turnId: string; folded: boolean }
  /**
   * Drop the turn carrying this user message and everything after it, matching
   * what `--resume-session-at` does to the conversation on the CLI side.
   */
  | { kind: "truncateBeforeUserMessage"; uuid: string }
  | { kind: "cachedModels"; models: ModelDescriptor[] }
  /**
   * The CLI's own settings defaults (`~/.claude/settings.json` "model" /
   * "effortLevel"), delivered with `harness.context`. Weakest model source:
   * display resolution consults them only when neither an init frame, a user
   * pick, a restore snapshot, nor replayed history has said anything stronger.
   */
  | { kind: "sessionDefaults"; model?: string; effort?: EffortLevel }
  | { kind: "historyTruncated" }
  /**
   * A history replay just finished draining. Replayed history has no `result`
   * frames (the native mapper forwards only user/assistant records), so its
   * final turn is still "streaming" — and the `runStarted` that follows a
   * resume would close it as an ERROR, painting "Failed after…" on a turn that
   * ended fine. This closes every open replayed turn as complete, at the time
   * of its own last frame rather than at wall-now.
   */
  | { kind: "historyReplayed" }
  /**
   * `preserveModelPick` marks the RESTORE-bootstrap reset (the pane's own
   * serialized session replayed on open), which is not the user moving to
   * another session: a model pick made while that replay was still loading
   * must survive it. The deliberate swaps — New Session, an explicit resume —
   * dispatch a plain reset, which clears the latch so the destination
   * session's own model can win.
   */
  | { kind: "reset"; preserveModelPick?: boolean };

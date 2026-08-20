export type Json = string | number | boolean | null | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

export type PermissionMode = "default" | "acceptEdits" | "plan" | "bypassPermissions";
export type EffortLevel = "low" | "medium" | "high" | "xhigh" | "max";
export type SessionState = "idle" | "running" | "requires_action";

export interface ModelDescriptor {
  value: string;
  resolvedModel?: string;
  displayName: string;
  description?: string;
  supportsEffort?: boolean;
  supportedEffortLevels?: EffortLevel[];
  defaultEffortLevel?: EffortLevel;
  supportsFastMode?: boolean;
}

export interface SlashCommandDescriptor {
  name: string;
  description?: string;
  argumentHint?: string;
}

export interface McpServerDescriptor {
  name: string;
  status?: string;
}

export interface InitializeResponse {
  commands?: SlashCommandDescriptor[];
  agents?: string[];
  output_style?: string;
  available_output_styles?: string[];
  models?: ModelDescriptor[];
  account?: { tokenSource?: string; apiProvider?: string };
  current_permission_mode?: PermissionMode;
  pending_permission_requests?: ControlRequestLine[];
}

export interface SystemInitLine {
  type: "system";
  subtype: "init";
  cwd?: string;
  session_id?: string;
  tools?: string[];
  slash_commands?: string[];
  mcp_servers?: McpServerDescriptor[];
  model?: string;
  permissionMode?: PermissionMode;
  agents?: string[];
  skills?: string[];
  output_style?: string;
  claude_code_version?: string;
  capabilities?: string[];
  uuid?: string;
}

export interface SystemStatusLine {
  type: "system";
  subtype: "status";
  status: "requesting" | "compacting" | null;
  permissionMode?: PermissionMode;
  compact_result?: string;
  compact_error?: string;
  uuid?: string;
}

export interface SystemSessionStateLine {
  type: "system";
  subtype: "session_state_changed";
  state: SessionState;
  uuid?: string;
}

export interface SystemCompactBoundaryLine {
  type: "system";
  subtype: "compact_boundary";
  compact_metadata?: { trigger?: string; pre_tokens?: number };
  uuid?: string;
}

export interface SystemThinkingTokensLine {
  type: "system";
  subtype: "thinking_tokens";
  estimated_tokens: number;
  estimated_tokens_delta?: number;
  uuid?: string;
}

export interface SystemApiRetryLine {
  type: "system";
  subtype: "api_retry";
  attempt: number;
  max_retries?: number;
  retry_delay_ms?: number;
  error?: string;
  uuid?: string;
}

export interface SystemInformationalLine {
  type: "system";
  subtype: "informational" | "notification" | "permission_denied" | "local_command_output";
  content?: string;
  level?: "info" | "warning" | "error";
  message?: string;
  uuid?: string;
}

export interface SystemHookLine {
  type: "system";
  subtype: "hook_started" | "hook_progress" | "hook_response";
  hook_id?: string;
  hook_name?: string;
  hook_event?: string;
  outcome?: string;
  exit_code?: number;
  uuid?: string;
}

export interface TaskUsage {
  total_tokens?: number;
  tool_uses?: number;
  duration_ms?: number;
}

/** One item of `task_progress.workflow_progress`, upserted by (type, index). */
export type WorkflowProgressItem =
  | { type: "workflow_phase"; index: number; title?: string; kind?: string }
  | {
      type: "workflow_agent";
      index: number;
      label?: string;
      phaseIndex?: number;
      phaseTitle?: string;
      agentId?: string;
      agentType?: string;
      isolation?: "worktree" | "remote" | string;
      model?: string;
      fallbackModel?: string;
      state?: "start" | "done" | "error" | string;
      startedAt?: number;
      queuedAt?: number;
      attempt?: number;
      lastAttemptReason?: string;
      lastToolName?: string;
      lastToolSummary?: string;
      promptPreview?: string;
      lastProgressAt?: number;
      tokens?: number;
      toolCalls?: number;
      durationMs?: number;
      resultPreview?: string;
      error?: string;
      blocked?: boolean;
      cached?: boolean;
    }
  | { type: "workflow_log"; message?: string }
  | { type: string; [key: string]: Json | undefined };

export interface SystemTaskLine {
  type: "system";
  subtype: "task_started" | "task_progress" | "task_updated" | "task_notification";
  task_id?: string;
  tool_use_id?: string;
  description?: string;
  subagent_type?: string;
  /** local_bash | local_agent | local_workflow. */
  task_type?: string;
  workflow_name?: string;
  workflow_progress?: WorkflowProgressItem[];
  prompt?: string;
  status?: string;
  summary?: string;
  output_file?: string;
  last_tool_name?: string;
  usage?: TaskUsage;
  skip_transcript?: boolean;
  patch?: {
    status?: string;
    end_time?: number;
    description?: string;
    error?: string;
    is_backgrounded?: boolean;
    total_paused_ms?: number;
    [key: string]: Json | undefined;
  };
  uuid?: string;
}

export interface SystemBackgroundTasksLine {
  type: "system";
  subtype: "background_tasks_changed";
  tasks?: Array<{
    task_id?: string;
    task_type?: string;
    description?: string;
    status?: string;
    subagent_type?: string;
    command?: string;
    agent_type?: string;
    usage?: TaskUsage;
  }>;
  uuid?: string;
}

export interface SystemRefusalFallbackLine {
  type: "system";
  subtype: "model_refusal_fallback";
  retracted_message_uuids?: string[];
  uuid?: string;
}

export interface SystemConversationResetLine {
  type: "system";
  subtype: "conversation_reset";
  uuid?: string;
}

export type SystemLine =
  | SystemInitLine
  | SystemStatusLine
  | SystemSessionStateLine
  | SystemCompactBoundaryLine
  | SystemThinkingTokensLine
  | SystemApiRetryLine
  | SystemInformationalLine
  | SystemHookLine
  | SystemTaskLine
  | SystemBackgroundTasksLine
  | SystemRefusalFallbackLine
  | SystemConversationResetLine
  | { type: "system"; subtype: string; [key: string]: Json | undefined };

export interface ContentBlockText {
  type: "text";
  text: string;
}

export interface ContentBlockThinking {
  type: "thinking";
  thinking: string;
  signature?: string;
}

export interface ContentBlockToolUse {
  type: "tool_use";
  id: string;
  name: string;
  input: JsonObject;
  caller?: { type?: string };
}

export interface ContentBlockToolResult {
  type: "tool_result";
  tool_use_id: string;
  content?: Json;
  is_error?: boolean;
}

export interface ContentBlockImage {
  type: "image";
  source: { type: "base64"; media_type: string; data: string };
}

export type ContentBlock =
  | ContentBlockText
  | ContentBlockThinking
  | ContentBlockToolUse
  | ContentBlockToolResult
  | ContentBlockImage
  | { type: string; [key: string]: Json | undefined };

export interface MessageUsage {
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
  output_tokens_details?: { thinking_tokens?: number };
}

export interface StreamEventLine {
  type: "stream_event";
  event: {
    type:
      | "message_start"
      | "content_block_start"
      | "content_block_delta"
      | "content_block_stop"
      | "message_delta"
      | "message_stop"
      | string;
    index?: number;
    message?: { id?: string; model?: string; usage?: MessageUsage };
    content_block?: ContentBlock;
    delta?: {
      type?: "text_delta" | "thinking_delta" | "input_json_delta" | "signature_delta" | string;
      text?: string;
      thinking?: string;
      partial_json?: string;
      signature?: string;
      stop_reason?: string;
      estimated_tokens?: number;
    };
    usage?: MessageUsage;
  };
  session_id?: string;
  parent_tool_use_id?: string | null;
  uuid?: string;
  ttft_ms?: number;
}

export type AssistantErrorKind =
  | "authentication_failed"
  | "billing_error"
  | "rate_limit"
  | "overloaded"
  | string;

export interface AssistantLine {
  type: "assistant";
  message: {
    id?: string;
    model?: string;
    role: "assistant";
    content: ContentBlock[];
    stop_reason?: string | null;
    usage?: MessageUsage;
  };
  parent_tool_use_id?: string | null;
  subagent_type?: string;
  task_description?: string;
  session_id?: string;
  uuid?: string;
  timestamp?: string;
  /**
   * The reasoning effort the frame was produced at. The CLI stamps it on the
   * DISK record of every assistant message ("effort":"xhigh"), which makes it
   * the one record a resumed session has of what it was actually running —
   * history carries no init frame. Live wire frames may omit it.
   */
  effort?: string;
  error?: AssistantErrorKind | { type?: string; message?: string };
  aborted?: boolean;
  supersedes?: string[];
}

export interface UserLine {
  type: "user";
  message: { role: "user"; content: string | ContentBlock[] };
  parent_tool_use_id?: string | null;
  subagent_type?: string;
  task_description?: string;
  session_id?: string;
  uuid?: string;
  timestamp?: string;
  isReplay?: boolean;
  isMeta?: boolean;
  tool_use_result?: JsonObject;
  /**
   * Synthesized by the native history mapper from a `queued_command`
   * attachment record: a message the user queued during a turn, which the CLI
   * consumed MID-TURN as context rather than answering as its own turn. It
   * renders inside the turn it interjected into — replaying it as a fresh user
   * turn would re-ask a question the transcript shows already answered.
   */
  mid_turn?: boolean;
}

/**
 * The CLI's own account of a queued message's life: `queued` when it accepts
 * one mid-turn, `started` the moment it feeds it to the model — on the next
 * STEP of the running turn, not the next turn — and `completed` when the work
 * it triggered settles. `command_uuid` is the uuid the client stamped on the
 * user-message frame, which is what ties a lifecycle event back to the chip
 * the composer is holding.
 */
export interface CommandLifecycleLine {
  type: "command_lifecycle";
  command_uuid?: string;
  state?: "queued" | "started" | "completed" | string;
  uuid?: string;
  session_id?: string;
}

export interface ResultLine {
  type: "result";
  subtype: "success" | "error_during_execution" | "error_max_turns" | string;
  is_error?: boolean;
  result?: string;
  duration_ms?: number;
  duration_api_ms?: number;
  num_turns?: number;
  total_cost_usd?: number;
  usage?: MessageUsage;
  modelUsage?: Record<string, { costUSD?: number; contextWindow?: number; [key: string]: Json | undefined }>;
  permission_denials?: JsonObject[];
  terminal_reason?: string;
  ttft_ms?: number;
  session_id?: string;
  uuid?: string;
}

export interface PermissionSuggestionAddRules {
  type: "addRules";
  rules: Array<{ toolName: string; ruleContent?: string }>;
  behavior: "allow" | "deny" | "ask";
  destination: "localSettings" | "projectSettings" | "userSettings" | "session" | string;
}

export interface PermissionSuggestionSetMode {
  type: "setMode";
  mode: PermissionMode;
  destination?: string;
}

export interface PermissionSuggestionAddDirectories {
  type: "addDirectories";
  directories: string[];
  destination?: string;
}

export type PermissionSuggestion =
  | PermissionSuggestionAddRules
  | PermissionSuggestionSetMode
  | PermissionSuggestionAddDirectories
  | { type: string; [key: string]: Json | undefined };

export interface CanUseToolRequest {
  subtype: "can_use_tool";
  tool_name: string;
  display_name?: string;
  input: JsonObject;
  title?: string;
  description?: string;
  permission_suggestions?: PermissionSuggestion[];
  blocked_path?: string;
  decision_reason?: string;
  decision_reason_type?: string;
  suppress_always_allow_rule?: boolean;
  tool_use_id?: string;
  agent_id?: string;
}

export interface ControlRequestLine {
  type: "control_request";
  request_id: string;
  request: CanUseToolRequest | { subtype: string; [key: string]: Json | undefined };
}

export interface ControlCancelRequestLine {
  type: "control_cancel_request";
  request_id: string;
}

export interface ControlResponseLine {
  type: "control_response";
  response: {
    subtype: "success" | "error";
    request_id: string;
    response?: JsonObject;
    error?: string;
  };
}

export type ProtocolLine =
  | SystemLine
  | StreamEventLine
  | AssistantLine
  | UserLine
  | ResultLine
  | ControlRequestLine
  | ControlCancelRequestLine
  | ControlResponseLine
  | CommandLifecycleLine
  | { type: "keep_alive" }
  | { type: string; [key: string]: Json | undefined };

export interface StructuredPatchHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: string[];
}

export interface TodoItem {
  content: string;
  status: "pending" | "in_progress" | "completed" | string;
  activeForm?: string;
}

export interface HarnessTheme {
  isDark: boolean;
  pageBackground: string;
  surfaceBackground: string;
  surfaceElevatedBackground: string;
  inputBackground: string;
  border: string;
  borderStrong: string;
  text: string;
  mutedText: string;
  softText: string;
  accent: string;
  accentSoft: string;
  danger: string;
  shadow: string;
}

export interface CliStatus {
  available: boolean;
  version?: string;
  path?: string;
  error?: string;
}

export interface SessionSummary {
  sessionId: string;
  title: string;
  updatedAtMs: number;
  firstPrompt?: string;
  gitBranch?: string;
  messageCount?: number;
}

export interface HarnessContext {
  panelId: string;
  workspaceId?: string;
  workingDirectory?: string;
  theme: HarnessTheme;
  copy: Record<string, string>;
  cliStatus: CliStatus;
  restore?: { sessionId: string; model?: string; permissionMode?: PermissionMode };
  draft?: string;
  /**
   * The model catalog persisted from a previous `initialize` handshake, keyed on
   * the resolved binary. It exists so the model menu has rows to show BEFORE the
   * first process start — the live catalog only arrives with the first run.
   */
  cachedModels?: ModelDescriptor[];
  /**
   * The CLI's own settings defaults, read from its settings files (project
   * `.claude/settings.local.json` and `.claude/settings.json` over the user's
   * `~/.claude/settings.json`): the `model` selector and `effortLevel` a
   * process started with no flags will actually run. Item 12: this is what
   * lets a fresh pane name the real model immediately instead of the catalog's
   * generic "Default (recommended)" row until the first send's init frame.
   * Weakest source — an init frame, a user pick, a restore snapshot, or
   * replayed history all outrank it.
   */
  defaults?: {
    model?: string;
    effort?: EffortLevel;
    /**
     * The model most recently USED by any harness pane on this machine
     * (recorded natively on every start-with-model, set_model ack, and init
     * frame; shared across panes through UserDefaults). Ranks ABOVE the
     * settings-file default — the CLI itself forgets a plain /model switch on
     * exit, and the user asked new panes to open on the last model used — but
     * still BELOW everything session-specific: a live init frame, a user
     * pick, a restore snapshot, and replayed history all outrank it.
     */
    lastUsed?: { model: string; effort?: EffortLevel };
  };
}

/** Where the harness will look for the Claude binary, and what it found. */
export interface BinarySetting {
  /** What resolution actually settled on, override or not. */
  resolvedPath?: string;
  /** The user's explicit override, if one is stored. */
  overridePath?: string;
  version?: string;
  /** Why resolution failed, when it did. */
  error?: string;
}

/** Dry-run answer from the CLI's `rewind_files` control request. */
export interface RewindPreview {
  canRewind: boolean;
  filesChanged: string[];
  insertions: number;
  deletions: number;
  /** Set when the CLI refused outright rather than answering with canRewind. */
  error?: string;
}

/**
 * What a completed `harness.rewind` answers. The two halves of a rewind fail
 * independently: the conversation restart is what the reply's existence reports,
 * while `rewind_files` can refuse on its own — a session with no checkpoints, a
 * CLI too old for the control request, a file the restore could not write. That
 * half used to be swallowed into a stderr event and reported to the user as
 * plain success, so the pane claimed to have restored files it had not touched.
 */
export interface RewindResult {
  runId: string;
  /**
   * False whenever file restore was requested and did not happen, AND whenever
   * it was never requested — the caller knows which of the two it asked for.
   */
  filesRestored: boolean;
  /** Short cause, present only when a requested restore failed. */
  reason?: string;
}

/**
 * A subagent's own transcript, read off disk
 * (`<session>/subagents/agent-<taskId>.jsonl`, or
 * `<session>/subagents/workflows/<runId>/agent-<agentId>.jsonl`) and mapped into
 * the SAME protocol shapes the live stream produces, so the drill-in replays
 * through the ordinary reducer instead of a second renderer.
 *
 * `missing: true` is the calm answer for a file that does not exist yet — an
 * agent that has only just been spawned has no file, and that is not an error.
 */
export interface SubagentTranscript {
  /** Logical source revision. Older mocks may omit it and are treated as replacements. */
  revision?: number;
  /** Whether retained consumer events must be replaced before applying this response. */
  replace?: boolean;
  /** Retained prefix events to discard before appending `events`. */
  droppedEventCount?: number;
  events: ProtocolLine[];
  truncated: boolean;
  missing?: boolean;
  /** Omitted means unchanged; `null` means deleted. */
  meta?: { agentType?: string; description?: string; spawnDepth?: number } | null;
}

/** Tail of a background shell's output file. */
export interface TaskOutput {
  text: string;
  truncated: boolean;
  missing: boolean;
}

export interface ContextUsageCategory {
  name: string;
  tokens: number;
  color?: string;
}

export interface ContextUsage {
  totalTokens: number;
  maxTokens: number;
  percentage: number;
  autoCompactThreshold?: number;
  isAutoCompactEnabled?: boolean;
  categories?: ContextUsageCategory[];
  model?: string;
}

export type NativeEvent =
  | { kind: "protocol"; line: ProtocolLine }
  | { kind: "runStarted"; runId: string; resumedSessionId?: string }
  | { kind: "runExited"; runId: string; status: number; error?: string }
  | { kind: "stderr"; text: string }
  | {
      kind: "outputOverflow";
      stream: "stdout" | "stderr";
      discardedByteCount: number;
      userMessage: string;
    }
  | { kind: "theme"; theme: HarnessTheme }
  // Pushed when a background catalog probe finishes, so a pane that opened with
  // no cached catalog fills its model menu without waiting for a first send.
  | { kind: "modelCatalog"; models: ModelDescriptor[] }
  // The CLI's auto-generated topic title, read from the session file after a
  // turn — the same title the terminal shows in its tab. A user rename wins.
  | { kind: "sessionTitle"; title: string };

/** Versioned native-to-document delivery contract. Sequences are contiguous. */
export interface NativeEventEnvelope {
  version: 1;
  documentEpoch: string;
  firstSequence: number;
  highestSequence: number;
  events: NativeEvent[];
}

/** Positive acknowledgement returned only after `highestSequence` is reduced. */
export interface NativeEventAcknowledgement {
  version: 1;
  documentEpoch: string;
  highestSequence: number;
}

/** Presentation visibility is independent from execution/document liveness. */
export interface PresentationVisibilityControl {
  documentEpoch: string;
  visible: boolean;
  targetSequence: number;
}

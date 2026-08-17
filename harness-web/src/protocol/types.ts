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

export interface SystemTaskLine {
  type: "system";
  subtype: "task_started" | "task_progress" | "task_updated" | "task_notification";
  task_id?: string;
  tool_use_id?: string;
  description?: string;
  subagent_type?: string;
  task_type?: string;
  prompt?: string;
  status?: string;
  summary?: string;
  output_file?: string;
  last_tool_name?: string;
  usage?: TaskUsage;
  patch?: { status?: string; end_time?: number; [key: string]: Json | undefined };
  uuid?: string;
}

export interface SystemBackgroundTasksLine {
  type: "system";
  subtype: "background_tasks_changed";
  tasks?: Array<{
    task_id?: string;
    description?: string;
    status?: string;
    subagent_type?: string;
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
  | { kind: "theme"; theme: HarnessTheme }
  // Pushed when a background catalog probe finishes, so a pane that opened with
  // no cached catalog fills its model menu without waiting for a first send.
  | { kind: "modelCatalog"; models: ModelDescriptor[] }
  // The CLI's auto-generated topic title, read from the session file after a
  // turn — the same title the terminal shows in its tab. A user rename wins.
  | { kind: "sessionTitle"; title: string };

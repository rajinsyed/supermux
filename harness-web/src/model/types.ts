import type {
  CanUseToolRequest,
  ContextUsage,
  EffortLevel,
  JsonObject,
  McpServerDescriptor,
  ModelDescriptor,
  PermissionMode,
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

export interface SubagentInfo {
  taskId?: string;
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
  background?: boolean;
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
  aborted?: boolean;
}

export interface DividerBlock {
  kind: "divider";
  key: string;
  variant: "compact" | "reset";
  trigger?: string;
  preTokens?: number;
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

export type Block = TextBlock | ThinkingBlock | ToolBlock | DividerBlock | NoticeBlock | ImageBlock;

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
  startedAtMs: number;
  endedAtMs?: number;
  state: TurnState;
  blocks: Block[];
  result?: TurnResult;
  errorText?: string;
  folded: boolean;
  revision: number;
}

export type PendingKind = "permission" | "question" | "plan" | "enterPlan";

export interface PendingPermission {
  requestId: string;
  kind: PendingKind;
  request: CanUseToolRequest;
  receivedAtMs: number;
}

export interface QueuedMessage {
  uuid: string;
  text: string;
  images?: ImageAttachment[];
  queuedAtMs: number;
}

export interface SessionMeta {
  sessionId?: string;
  cwd?: string;
  model?: string;
  modelDisplayName?: string;
  effort?: EffortLevel;
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
  createdAtMs: number;
  retry?: { attempt: number; maxRetries?: number; retryDelayMs?: number };
}

export interface BackgroundTask {
  taskId: string;
  description?: string;
  subagentType?: string;
  status?: string;
  totalTokens?: number;
  toolUses?: number;
  durationMs?: number;
}

export interface TranscriptModel {
  generation: number;
  session: SessionMeta;
  turns: Turn[];
  pending: PendingPermission[];
  queued: QueuedMessage[];
  todos: TodoItem[];
  usage: UsageTotals;
  contextUsage?: ContextUsage;
  activity: ActivityState;
  banners: Banner[];
  backgroundTasks: BackgroundTask[];
  runPhase: RunPhase;
  runId?: string;
  exitError?: string;
  /** The process never started, as opposed to starting and later exiting. */
  startFailed?: boolean;
  stderrTail: string[];
  revision: number;
}

export type LocalAction =
  | { kind: "localSend"; uuid: string; text: string; images?: ImageAttachment[]; atMs: number }
  | { kind: "cancelQueued"; uuid: string }
  | { kind: "permissionResolved"; requestId: string }
  | { kind: "contextUsage"; usage: ContextUsage }
  | { kind: "setTitle"; title: string }
  | { kind: "setModel"; model: string; effort?: EffortLevel }
  | { kind: "setPermissionMode"; mode: PermissionMode }
  | { kind: "startFailed"; error?: string }
  | { kind: "dismissBanner"; id: string }
  | { kind: "toggleFold"; turnId: string; folded: boolean }
  | { kind: "reset" };

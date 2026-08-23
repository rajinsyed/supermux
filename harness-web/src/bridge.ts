import type {
  BinarySetting,
  ContextUsage,
  EffortLevel,
  HarnessContext,
  HarnessTheme,
  NativeEvent,
  NativeEventAcknowledgement,
  NativeEventEnvelope,
  PermissionMode,
  PresentationVisibilityControl,
  PermissionSuggestion,
  ProtocolLine,
  RewindPreview,
  RewindResult,
  SessionSummary,
  SubagentTranscript,
  TaskOutput
} from "./protocol/types";

export type AttachmentErrorCode =
  | "unsupportedMediaType"
  | "invalidImage"
  | "imageTooLarge"
  | "totalTooLarge"
  | "tooManyImages";

export interface ImagePayload {
  mediaType: string;
  dataBase64: string;
  name?: string;
}

export interface StartParams {
  resumeSessionId?: string;
  forkSession?: boolean;
  model?: string;
  permissionMode?: PermissionMode;
  effort?: EffortLevel;
}

export interface HarnessBridge {
  context(): Promise<HarnessContext>;
  listSessions(params?: { limit?: number }): Promise<{ sessions: SessionSummary[] }>;
  loadSessionHistory(params: { sessionId: string }): Promise<{ events: ProtocolLine[]; truncated: boolean }>;
  start(params?: StartParams): Promise<{ runId: string }>;
  /**
   * Stop whatever is running (awaiting full teardown) and start again. `start`
   * keeps its already-running guard for direct calls; every user-facing
   * "resume this session" / "new session" path goes through here, which is why
   * picking a session while a process ran used to fail outright.
   *
   * An absent `resumeSessionId` means a genuinely fresh session — the native
   * side must NOT fall back to the restore snapshot. Resume policy lives in the
   * web layer, which is the only place that knows which session the pane is on.
   */
  restart(params?: StartParams): Promise<{ runId: string }>;
  /** Open another Claude pane already pointed at `sessionId`. */
  openSessionInNewPane(params: { sessionId: string }): Promise<void>;
  send(params: { text: string; images?: ImagePayload[]; uuid: string }): Promise<{ sent: boolean }>;
  interrupt(params: { cancelQueued: boolean }): Promise<void>;
  cancelQueued(params: { messageUuid: string }): Promise<void>;
  stop(): Promise<void>;
  setModel(params: { model: string; effort?: EffortLevel }): Promise<void>;
  setPermissionMode(params: { mode: PermissionMode }): Promise<void>;
  respondPermission(params: {
    requestId: string;
    behavior: "allow" | "deny";
    updatedInput?: unknown;
    updatedPermissions?: PermissionSuggestion[];
    message?: string;
    interrupt?: boolean;
  }): Promise<void>;
  renameSession(params: { title: string }): Promise<void>;
  getContextUsage(): Promise<ContextUsage>;
  fileSuggestions(params: { query: string }): Promise<{ paths: string[] }>;
  pickFiles(): Promise<{
    images: ImagePayload[];
    paths: string[];
    attachmentError?: AttachmentErrorCode;
  }>;
  openFile(params: { path: string }): Promise<void>;
  copyText(params: { text: string }): Promise<void>;
  saveFile(params: { suggestedName: string; text: string }): Promise<{ saved: boolean }>;
  notify(params: { title: string; body: string }): Promise<void>;
  saveDraft(params: { text: string }): Promise<void>;
  getBinarySetting(): Promise<BinarySetting>;
  /** An empty or absent path clears the override. Rejects on a bad path. */
  setBinaryPath(params: { path?: string }): Promise<BinarySetting>;
  /** Dry run: what a rewind to this user message would restore. */
  rewindPreview(params: { userMessageUuid: string }): Promise<RewindPreview>;
  /**
   * Restore files to their state when `userMessageUuid` was sent, then restart
   * the conversation truncated to just BEFORE it. `resumeAtUuid` is the uuid of
   * the PREVIOUS user message (`--resume-session-at`); omitting it means the
   * rewind target was the first message, so the new run is a fresh session.
   *
   * The reply reports the two halves separately: resolving at all means the
   * conversation was rewound, and `filesRestored` says whether the file half
   * actually happened. A `rewind_files` refusal is NOT an error — the
   * conversation rewind still stands — so it comes back as
   * `{filesRestored: false, reason}` rather than a rejection.
   */
  rewind(params: {
    userMessageUuid: string;
    restoreFiles: boolean;
    resumeAtUuid?: string;
  }): Promise<RewindResult>;
  /** `control_request {subtype: "stop_task", task_id}` — kills a background task. */
  stopTask(params: { taskId: string }): Promise<void>;
  /**
   * `control_request {subtype: "background_tasks", tool_use_id?}` — the CLI's
   * ctrl+B. Omitting `toolUseId` backgrounds every foreground task at once.
   */
  backgroundTask(params: { toolUseId?: string }): Promise<{ backgrounded: boolean }>;
  /**
   * A revisioned subagent transcript replacement or delta from disk. `taskId`
   * addresses a `local_agent`; `workflowRunId` + `agentId` addresses one workflow agent.
   */
  loadSubagentTranscript(params: {
    taskId?: string;
    workflowRunId?: string;
    agentId?: string;
    afterRevision?: number;
  }): Promise<SubagentTranscript>;
  /**
   * Tail of a background shell's output file (~last 64KB). The payload carries
   * ONLY the task id: the native side resolves the path from the frames it saw,
   * never from anything the web layer hands it.
   */
  readTaskOutput(params: { taskId: string }): Promise<TaskOutput>;
}

export interface BridgeError {
  code: string;
  userMessage: string;
}

export class HarnessBridgeError extends Error {
  readonly code: string;
  constructor(error: BridgeError) {
    super(error.userMessage);
    this.name = "HarnessBridgeError";
    this.code = error.code;
  }
}

interface WebkitHandler {
  postMessage(message: unknown): Promise<unknown>;
}

interface HarnessGlobal {
  receiveBatch(events: NativeEvent[]): void;
  receiveEnvelope(envelope: unknown): NativeEventAcknowledgement | undefined;
  setPresentationVisibility(control: unknown): boolean;
  applyTheme(theme: HarnessTheme): void;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { supermuxHarness?: WebkitHandler } };
    supermuxHarness?: HarnessGlobal;
    supermuxHarnessMock?: HarnessBridge;
  }
}

let requestCounter = 0;

function nativeHandler(): WebkitHandler | undefined {
  return window.webkit?.messageHandlers?.supermuxHarness;
}

export function hasNativeBridge(): boolean {
  return nativeHandler() !== undefined;
}

async function callNative<T>(method: string, params?: unknown): Promise<T> {
  const handler = nativeHandler();
  if (!handler) throw new HarnessBridgeError({ code: "no_bridge", userMessage: "Native bridge unavailable" });
  requestCounter += 1;
  const raw = await handler.postMessage({ id: `req-${requestCounter}`, method, params: params ?? {} });
  const envelope = raw as { ok?: boolean; value?: T; error?: BridgeError } | undefined;
  if (!envelope || envelope.ok !== true) {
    throw new HarnessBridgeError(
      envelope?.error ?? { code: "unknown", userMessage: "The request failed." }
    );
  }
  return envelope.value as T;
}

const nativeBridge: HarnessBridge = {
  context: () => callNative("harness.context"),
  listSessions: (params) => callNative("harness.listSessions", params),
  loadSessionHistory: (params) => callNative("harness.loadSessionHistory", params),
  start: (params) => callNative("harness.start", params),
  restart: (params) => callNative("harness.restart", params),
  openSessionInNewPane: (params) => callNative("harness.openSessionInNewPane", params),
  send: (params) => callNative("harness.send", params),
  interrupt: (params) => callNative("harness.interrupt", params),
  cancelQueued: (params) => callNative("harness.cancelQueued", params),
  stop: () => callNative("harness.stop"),
  setModel: (params) => callNative("harness.setModel", params),
  setPermissionMode: (params) => callNative("harness.setPermissionMode", params),
  respondPermission: (params) => callNative("harness.respondPermission", params),
  renameSession: (params) => callNative("harness.renameSession", params),
  getContextUsage: () => callNative("harness.getContextUsage"),
  fileSuggestions: (params) => callNative("harness.fileSuggestions", params),
  pickFiles: () => callNative("harness.pickFiles"),
  openFile: (params) => callNative("harness.openFile", params),
  copyText: (params) => callNative("harness.copyText", params),
  saveFile: (params) => callNative("harness.saveFile", params),
  notify: (params) => callNative("harness.notify", params),
  saveDraft: (params) => callNative("harness.saveDraft", params),
  getBinarySetting: () => callNative("harness.getBinarySetting"),
  setBinaryPath: (params) => callNative("harness.setBinaryPath", params),
  rewindPreview: (params) => callNative("harness.rewindPreview", params),
  rewind: (params) => callNative("harness.rewind", params),
  stopTask: (params) => callNative("harness.stopTask", params),
  backgroundTask: (params) => callNative("harness.backgroundTask", params),
  loadSubagentTranscript: (params) => callNative("harness.loadSubagentTranscript", params),
  readTaskOutput: (params) => callNative("harness.readTaskOutput", params)
};

export function getBridge(): HarnessBridge {
  if (hasNativeBridge()) return nativeBridge;
  const mock = window.supermuxHarnessMock;
  if (mock) return mock;
  throw new HarnessBridgeError({
    code: "no_bridge",
    userMessage: "No harness bridge is available in this context."
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isHarnessTheme(value: unknown): value is HarnessTheme {
  if (!isRecord(value) || typeof value.isDark !== "boolean") return false;
  const colorKeys = [
    "pageBackground",
    "surfaceBackground",
    "surfaceElevatedBackground",
    "inputBackground",
    "border",
    "borderStrong",
    "text",
    "mutedText",
    "softText",
    "accent",
    "accentSoft",
    "danger",
    "shadow"
  ];
  return colorKeys.every((key) => typeof value[key] === "string");
}

function isNativeEvent(value: unknown): value is NativeEvent {
  if (!isRecord(value) || typeof value.kind !== "string") return false;
  switch (value.kind) {
    case "protocol":
      return isRecord(value.line);
    case "runStarted":
      return typeof value.runId === "string";
    case "runExited":
      return (
        typeof value.runId === "string" &&
        typeof value.status === "number" &&
        Number.isFinite(value.status)
      );
    case "stderr":
      return typeof value.text === "string";
    case "outputOverflow":
      return (
        (value.stream === "stdout" || value.stream === "stderr") &&
        typeof value.discardedByteCount === "number" &&
        Number.isFinite(value.discardedByteCount) &&
        value.discardedByteCount >= 0 &&
        typeof value.userMessage === "string"
      );
    case "theme":
      return isHarnessTheme(value.theme);
    case "modelCatalog":
      return (
        Array.isArray(value.models) &&
        value.models.every(
          (model) =>
            isRecord(model) &&
            typeof model.value === "string" &&
            typeof model.displayName === "string"
        )
      );
    case "sessionTitle":
      return typeof value.title === "string";
    default:
      return false;
  }
}

function parseNativeEventEnvelope(value: unknown): NativeEventEnvelope | undefined {
  if (
    !isRecord(value) ||
    value.version !== 1 ||
    typeof value.documentEpoch !== "string" ||
    value.documentEpoch.length === 0 ||
    typeof value.firstSequence !== "number" ||
    typeof value.highestSequence !== "number" ||
    !Number.isSafeInteger(value.firstSequence) ||
    !Number.isSafeInteger(value.highestSequence) ||
    value.firstSequence < 1 ||
    value.highestSequence < value.firstSequence ||
    !Array.isArray(value.events) ||
    value.events.length === 0 ||
    !value.events.every(isNativeEvent) ||
    value.highestSequence - value.firstSequence + 1 !== value.events.length
  ) {
    return undefined;
  }
  return {
    version: 1,
    documentEpoch: value.documentEpoch,
    firstSequence: value.firstSequence,
    highestSequence: value.highestSequence,
    events: value.events
  };
}

function parsePresentationVisibility(
  value: unknown
): PresentationVisibilityControl | undefined {
  if (
    !isRecord(value) ||
    typeof value.documentEpoch !== "string" ||
    value.documentEpoch.length === 0 ||
    typeof value.visible !== "boolean" ||
    typeof value.targetSequence !== "number" ||
    !Number.isSafeInteger(value.targetSequence) ||
    value.targetSequence < 0
  ) {
    return undefined;
  }
  return {
    documentEpoch: value.documentEpoch,
    visible: value.visible,
    targetSequence: value.targetSequence
  };
}

export function installReceiver(handlers: {
  onBatch(events: NativeEvent[]): void;
  onEnvelope(envelope: NativeEventEnvelope): NativeEventAcknowledgement | undefined;
  onPresentationVisibility(control: PresentationVisibilityControl): boolean;
  onTheme(theme: HarnessTheme): void;
}): void {
  let themeDocumentEpoch: string | undefined;
  let themeHighestSequence = 0;
  window.supermuxHarness = {
    receiveBatch: (events) => {
      if (!Array.isArray(events)) return;
      handlers.onBatch(events);
      for (const event of events) {
        if (event && event.kind === "theme") handlers.onTheme(event.theme);
      }
    },
    receiveEnvelope: (value) => {
      const envelope = parseNativeEventEnvelope(value);
      if (!envelope) return undefined;
      const acknowledgement = handlers.onEnvelope(envelope);
      if (
        !acknowledgement ||
        acknowledgement.version !== 1 ||
        acknowledgement.documentEpoch !== envelope.documentEpoch ||
        acknowledgement.highestSequence !== envelope.highestSequence
      ) {
        return undefined;
      }
      const newlyApplied =
        themeDocumentEpoch !== envelope.documentEpoch ||
        themeHighestSequence < envelope.highestSequence;
      if (newlyApplied) {
        for (const event of envelope.events) {
          if (event.kind === "theme") handlers.onTheme(event.theme);
        }
        themeDocumentEpoch = envelope.documentEpoch;
        themeHighestSequence = envelope.highestSequence;
      }
      return acknowledgement;
    },
    setPresentationVisibility: (value) => {
      const control = parsePresentationVisibility(value);
      if (!control || !handlers.onPresentationVisibility(control)) return false;
      const expected = control.visible ? "visible" : "hidden";
      return document.documentElement.dataset.supermuxPresentation === expected;
    },
    applyTheme: (theme) => handlers.onTheme(theme)
  };
}
